import Combine
import Foundation

enum LoginDesktopBootstrapState: Equatable, Sendable {
    case inactive
    case restoringLibrary
    case preparingPlayback
    case enteringDesktop
    case active
    case failed
    case cancelled
}

enum DesktopPresetPreparationResult: Equatable, Sendable {
    case prepared
    case noActiveQueue
    case persistenceFailed
}

enum DesktopPresetPersistenceFailure: Equatable, Sendable {
    case saveFailed
    case clearFailed
    case invalidationFailed
}

enum DesktopPresetInvalidation: Equatable, Sendable {
    case noActiveQueue
    case missingPreset
    case invalidPreset
    case permanentlyUnavailable
}

struct DesktopPresetPersistencePolicy: Sendable {
    let stateChangeCoalescingDelay: Duration
    let minimumSnapshotSaveInterval: Duration
    let progressSaveDelay: Duration
    let failureRetryDelay: Duration

    /// Queue/progress uses a slower, staggered checkpoint than the playback
    /// session so both large JSON files are not rewritten per clip.
    static let production = DesktopPresetPersistencePolicy(
        stateChangeCoalescingDelay: .seconds(1),
        minimumSnapshotSaveInterval: .seconds(60),
        progressSaveDelay: .seconds(60),
        failureRetryDelay: .seconds(60)
    )

    static let immediate = DesktopPresetPersistencePolicy(
        stateChangeCoalescingDelay: .zero,
        minimumSnapshotSaveInterval: .zero,
        progressSaveDelay: .zero,
        // Zero disables automatic retries so deterministic callers cannot
        // create a tight failure loop.
        failureRetryDelay: .zero
    )
}

@MainActor
final class DesktopPresetController: ObservableObject {
    private enum PersistenceUrgency: Int {
        case progress
        case queueChange
        case stateChange
        case immediate
    }

    private enum AutomaticRestorePreparationState: Equatable {
        case unreconciled
        case disabled
        case prepared
        case unknown
    }

    @Published private(set) var bootstrapState:
        LoginDesktopBootstrapState = .inactive
    @Published private(set) var persistenceFailure:
        DesktopPresetPersistenceFailure? = nil
    @Published private(set) var automaticRestoreInvalidation:
        DesktopPresetInvalidation? = nil

    var isBootstrapping: Bool {
        switch bootstrapState {
        case .restoringLibrary, .preparingPlayback, .enteringDesktop:
            true
        case .inactive, .active, .failed, .cancelled:
            false
        }
    }

    private let playback: PlaybackCoordinator
    private let library: MediaLibraryCoordinator
    private let desktopSession: DesktopSessionCoordinator
    private let store: any DesktopPresetStoring
    private let restorer: PlaybackStateRestorer
    private let persistencePolicy: DesktopPresetPersistencePolicy
    private let persistenceClock = ContinuousClock()

    private var automaticRestorePreparationState:
        AutomaticRestorePreparationState = .unreconciled
    private var isAutomaticRestorePrepared: Bool {
        automaticRestorePreparationState == .prepared
    }
    private var shouldPreserveStoredPreset = false
    private var persistenceGeneration: UInt64 = 0
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskGeneration: UInt64?
    private var persistenceTaskUrgency: PersistenceUrgency?
    private var pendingPersistenceUrgency: PersistenceUrgency?
    private var lastSnapshotSaveInstant: ContinuousClock.Instant?
    private var retryNotBefore: ContinuousClock.Instant?
    private var blockedQueueStructureRevision: UInt64?
    private var lastCommittedPreset: DesktopPreset?
    private var isExternalRestoreInProgress = false
    private var isShuttingDown = false
    private var cancellables: Set<AnyCancellable> = []

#if DEBUG
    private(set) var queueSnapshotConstructionCount = 0
#endif

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        desktopSession: DesktopSessionCoordinator,
        store: any DesktopPresetStoring,
        persistencePolicy: DesktopPresetPersistencePolicy = .production
    ) {
        self.playback = playback
        self.library = library
        self.desktopSession = desktopSession
        self.store = store
        self.persistencePolicy = persistencePolicy
        restorer = PlaybackStateRestorer(
            playback: playback,
            library: library,
            desktopSession: desktopSession
        )
        observePresetChanges()
    }

    func restoreAtLogin(
        after libraryStart: MediaLibraryStartDisposition
    ) async -> Bool {
        bootstrapState = .restoringLibrary

        let preset: DesktopPreset
        do {
            guard let storedPreset = try await store.load() else {
                automaticRestoreInvalidation = .missingPreset
                bootstrapState = .failed
                return false
            }
            guard storedPreset.isValid else {
                await invalidateStoredPreset(reason: .invalidPreset)
                bootstrapState = .failed
                return false
            }
            preset = storedPreset
            lastCommittedPreset = storedPreset
        } catch is DesktopPresetStoreError {
            // Typed store errors describe permanently invalid persisted
            // content, including byte/count limits, and must use the existing
            // fail-closed invalidation path. Transport failures remain
            // temporary on the generic path below.
            guard !Task.isCancelled else {
                bootstrapState = .cancelled
                return false
            }
            await invalidateStoredPreset(reason: .invalidPreset)
            bootstrapState = .failed
            return false
        } catch is DecodingError {
            guard !Task.isCancelled else {
                bootstrapState = .cancelled
                return false
            }
            await invalidateStoredPreset(reason: .invalidPreset)
            bootstrapState = .failed
            return false
        } catch {
            bootstrapState = .failed
            return false
        }

        let restoreResult = await restorer.restore(
            preset,
            after: libraryStart,
            target: .desktop
        ) { [weak self] phase in
            switch phase {
            case .restoringLibrary:
                self?.bootstrapState = .restoringLibrary
            case .preparingPlayback:
                self?.bootstrapState = .preparingPlayback
            case .enteringDesktop:
                self?.bootstrapState = .enteringDesktop
            }
        }

        switch restoreResult {
        case .restored:
            shouldPreserveStoredPreset = false
            automaticRestoreInvalidation = nil
            bootstrapState = .active
            scheduleSave(urgency: .immediate)
            return true
        case .cancelled:
            shouldPreserveStoredPreset = true
            bootstrapState = .cancelled
            return false
        case .temporarilyUnavailable:
            shouldPreserveStoredPreset = true
            bootstrapState = .failed
            return false
        case .permanentlyUnavailable:
            await invalidateStoredPreset(reason: .permanentlyUnavailable)
            bootstrapState = .failed
            return false
        }
    }

    func markDesktopActive() {
        guard !isBootstrapping else {
            return
        }
        shouldPreserveStoredPreset = false
        bootstrapState = .active
        scheduleSave(urgency: .immediate)
    }

    func markDesktopInactive() {
        if bootstrapState == .active || bootstrapState == .cancelled {
            bootstrapState = .inactive
        }
    }

    func beginExternalRestore() {
        guard !isShuttingDown, !isExternalRestoreInProgress else {
            return
        }
        isExternalRestoreInProgress = true
        shouldPreserveStoredPreset = true
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
    }

    func finishExternalRestore(commitCurrentState: Bool) {
        guard isExternalRestoreInProgress else {
            return
        }
        isExternalRestoreInProgress = false
        guard commitCurrentState else {
            shouldPreserveStoredPreset = true
            return
        }
        guard isAutomaticRestorePrepared else {
            return
        }
        shouldPreserveStoredPreset = false
        synchronizePreset(urgency: .stateChange)
    }

    func setAutomaticRestorePrepared(_ isPrepared: Bool) {
        guard !isShuttingDown else {
            return
        }
        let nextState: AutomaticRestorePreparationState = isPrepared
            ? .prepared
            : .disabled
        guard automaticRestorePreparationState != nextState else {
            return
        }
        automaticRestorePreparationState = nextState
        if isPrepared {
            guard library.hasActiveQueue else {
                shouldPreserveStoredPreset = true
                return
            }
            shouldPreserveStoredPreset = false
            scheduleSave(urgency: .immediate)
        } else {
            shouldPreserveStoredPreset = false
            scheduleClear()
        }
    }

    func preserveAutomaticRestoreWhileStatusIsUnknown() {
        guard !isShuttingDown,
              automaticRestorePreparationState != .unknown else {
            return
        }
        automaticRestorePreparationState = .unknown
        shouldPreserveStoredPreset = true
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
    }

    func prepareAutomaticRestore() async ->
        DesktopPresetPreparationResult {
        guard !isShuttingDown, !Task.isCancelled else {
            return .persistenceFailed
        }
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
        await previousTask?.value

        guard !isShuttingDown, !Task.isCancelled else {
            return .persistenceFailed
        }
        guard library.hasActiveQueue else {
            return .noActiveQueue
        }
        guard let preset = makePreset() else {
            return .noActiveQueue
        }

        if await savePreset(preset) {
            automaticRestoreInvalidation = nil
            return .prepared
        }
        return .persistenceFailed
    }

    func discardPreparedAutomaticRestore() async {
        guard !isAutomaticRestorePrepared, !isShuttingDown else {
            return
        }
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
        await previousTask?.value
        await clearStoredPreset()
    }

    func markBootstrapCancelled() {
        guard isBootstrapping else {
            return
        }
        shouldPreserveStoredPreset = true
        bootstrapState = .cancelled
    }

    func preserveCurrentPreset() {
        guard isAutomaticRestorePrepared else {
            return
        }
        scheduleSave(urgency: .immediate)
    }

    func prepareForShutdown() async {
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
        await previousTask?.value

        guard !isExternalRestoreInProgress else {
            return
        }
        switch automaticRestorePreparationState {
        case .unknown, .unreconciled:
            return
        case .disabled:
            await clearStoredPreset()
            return
        case .prepared:
            break
        }
        guard !shouldPreserveStoredPreset else {
            return
        }
        guard library.hasActiveQueue else {
            await clearStoredPreset()
            return
        }
        guard let preset = makePreset() else {
            await clearStoredPreset()
            return
        }
        _ = await savePreset(preset, forceWrite: true)
    }

    private func observePresetChanges() {
        library.$queueRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.synchronizePreset(urgency: .queueChange)
            }
            .store(in: &cancellables)

        library.$queueStructureRevision
            .dropFirst()
            .sink { [weak self] revision in
                self?.synchronizePreset(
                    urgency: .stateChange,
                    observedQueueStructureRevision: revision
                )
            }
            .store(in: &cancellables)

        Publishers.MergeMany([
            playback.$isPlaybackRequested
                .removeDuplicates()
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            playback.$settings
                .map(\.rate)
                .removeDuplicates()
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            desktopSession.$videoContentMode
                .removeDuplicates()
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher()
        ])
        .sink { [weak self] in
            self?.synchronizePreset(urgency: .stateChange)
        }
        .store(in: &cancellables)

        playback.$currentTime
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleProgressSaveIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func scheduleProgressSaveIfNeeded() {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isExternalRestoreInProgress,
              !isBootstrapping else {
            return
        }
        scheduleSave(urgency: .progress)
    }

    private func scheduleSave(
        urgency: PersistenceUrgency,
        observedQueueStructureRevision: UInt64? = nil
    ) {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isExternalRestoreInProgress,
              !isBootstrapping,
              library.hasActiveQueue else {
            return
        }
        let effectiveQueueStructureRevision =
            observedQueueStructureRevision ?? library.queueStructureRevision
        if urgency != .immediate,
           blockedQueueStructureRevision == effectiveQueueStructureRevision {
            return
        }
        if let currentUrgency = persistenceTaskUrgency,
           currentUrgency.rawValue >= urgency.rawValue {
            retainPendingPersistenceUrgency(urgency)
            return
        }

        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        previousTask?.cancel()

        persistenceTaskGeneration = generation
        persistenceTaskUrgency = urgency
        pendingPersistenceUrgency = nil
        persistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishPersistenceTask(generation: generation)
            }
            await previousTask?.value
            let delay = persistenceDelay(for: urgency)
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled,
                  generation == persistenceGeneration else {
                return
            }
            pendingPersistenceUrgency = nil
            let queueStructureRevisionAtSnapshot =
                library.queueStructureRevision
            guard let preset = makePreset() else {
                return
            }
            _ = await savePreset(
                preset,
                queueStructureRevisionAtSnapshot:
                    queueStructureRevisionAtSnapshot,
                expectedGeneration: generation
            )
        }
    }

    private func scheduleClear() {
        guard !isShuttingDown else {
            return
        }
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        previousTask?.cancel()

        persistenceTaskGeneration = generation
        persistenceTaskUrgency = .immediate
        pendingPersistenceUrgency = nil
        persistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishPersistenceTask(generation: generation)
            }
            await previousTask?.value
            guard !Task.isCancelled,
                  generation == persistenceGeneration else {
                return
            }
            await clearStoredPreset()
        }
    }

    private func finishPersistenceTask(generation: UInt64) {
        guard persistenceTaskGeneration == generation else {
            return
        }
        persistenceTaskGeneration = nil
        persistenceTask = nil
        persistenceTaskUrgency = nil
        let pendingUrgency = pendingPersistenceUrgency
        pendingPersistenceUrgency = nil
        if let pendingUrgency {
            synchronizePreset(urgency: pendingUrgency)
        }
    }

    private func retainPendingPersistenceUrgency(
        _ urgency: PersistenceUrgency
    ) {
        if let pendingPersistenceUrgency,
           pendingPersistenceUrgency.rawValue >= urgency.rawValue {
            return
        }
        pendingPersistenceUrgency = urgency
    }

    private func synchronizePreset(
        urgency: PersistenceUrgency,
        observedQueueStructureRevision: UInt64? = nil
    ) {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isExternalRestoreInProgress,
              !isBootstrapping else {
            return
        }
        if !library.hasActiveQueue {
            guard !shouldPreserveStoredPreset else {
                return
            }
            automaticRestoreInvalidation = .noActiveQueue
            scheduleClear()
        } else {
            shouldPreserveStoredPreset = false
            automaticRestoreInvalidation = nil
            scheduleSave(
                urgency: urgency,
                observedQueueStructureRevision:
                    observedQueueStructureRevision
            )
        }
    }

    private func invalidateStoredPreset(
        reason: DesktopPresetInvalidation
    ) async {
        shouldPreserveStoredPreset = false
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
        await previousTask?.value
        await clearStoredPreset()
        automaticRestoreInvalidation = reason
    }

    private func clearStoredPreset() async {
        do {
            try await store.clear()
            lastCommittedPreset = nil
            persistenceFailure = nil
            lastSnapshotSaveInstant = nil
            retryNotBefore = nil
            blockedQueueStructureRevision = nil
        } catch {
            persistenceFailure = .clearFailed
        }
    }

    @discardableResult
    private func savePreset(
        _ preset: DesktopPreset,
        queueStructureRevisionAtSnapshot: UInt64? = nil,
        expectedGeneration: UInt64? = nil,
        forceWrite: Bool = false
    ) async -> Bool {
        let attemptedQueueStructureRevision =
            queueStructureRevisionAtSnapshot ?? library.queueStructureRevision
        if !forceWrite, preset == lastCommittedPreset {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            persistenceFailure = nil
            retryNotBefore = nil
            blockedQueueStructureRevision = nil
            return true
        }
        do {
            try await store.save(preset)
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            lastCommittedPreset = preset
            persistenceFailure = nil
            lastSnapshotSaveInstant = persistenceClock.now
            retryNotBefore = nil
            blockedQueueStructureRevision = nil
            return true
        } catch {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            let shouldRetry = registerSaveFailure(
                error,
                attemptedQueueStructureRevision:
                    attemptedQueueStructureRevision
            )
            if shouldRetry, expectedGeneration != nil {
                retainPendingPersistenceUrgency(.stateChange)
            }
            await failClosedAfterSaveFailure(
                expectedGeneration: expectedGeneration
            )
            return false
        }
    }

    private func failClosedAfterSaveFailure(
        expectedGeneration: UInt64? = nil
    ) async {
        guard expectedGeneration == nil
                || expectedGeneration == persistenceGeneration else {
            return
        }
        lastCommittedPreset = nil
        do {
            try await store.clear()
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return
            }
            persistenceFailure = .saveFailed
        } catch {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return
            }
            persistenceFailure = .invalidationFailed
        }
    }

    private func makePreset() -> DesktopPreset? {
#if DEBUG
        queueSnapshotConstructionCount += 1
#endif
        guard let queue = library.makeQueueSnapshot() else {
            return nil
        }
        return DesktopPreset(
            queue: queue,
            currentTime: playback.currentTime,
            isPlaybackRequested: playback.isPlaybackRequested,
            playbackRate: playback.settings.rate,
            videoContentMode: desktopSession.videoContentMode
        )
    }

    private func persistenceDelay(
        for urgency: PersistenceUrgency
    ) -> Duration {
        guard urgency != .immediate else {
            return .zero
        }

        var delay = urgency == .progress
            ? persistencePolicy.progressSaveDelay
            : persistencePolicy.stateChangeCoalescingDelay
        let now = persistenceClock.now
        if urgency == .progress || urgency == .queueChange,
           let lastSnapshotSaveInstant {
            let nextSnapshotSave = lastSnapshotSaveInstant.advanced(
                by: persistencePolicy.minimumSnapshotSaveInterval
            )
            let minimumIntervalDelay = now.duration(to: nextSnapshotSave)
            if minimumIntervalDelay > delay {
                delay = minimumIntervalDelay
            }
        }
        if let retryNotBefore {
            let retryDelay = now.duration(to: retryNotBefore)
            if retryDelay > delay {
                delay = retryDelay
            }
        }
        return max(delay, .zero)
    }

    private func registerSaveFailure(
        _ error: any Error,
        attemptedQueueStructureRevision: UInt64
    ) -> Bool {
        switch error as? DesktopPresetStoreError {
        case .fileTooLarge?, .queueLimitExceeded?:
            blockedQueueStructureRevision = attemptedQueueStructureRevision
            retryNotBefore = nil
            return false
        case .invalidPreset?, nil:
            guard persistencePolicy.failureRetryDelay > .zero else {
                retryNotBefore = nil
                return false
            }
            retryNotBefore = persistenceClock.now.advanced(
                by: persistencePolicy.failureRetryDelay
            )
            return true
        }
    }
}
