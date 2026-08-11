import Combine
import Foundation

enum PlaybackSessionPlanResult: Equatable, Sendable {
    case restore(PlaybackSessionRestorePlan)
    case noSnapshot
    case invalidSnapshot
    case temporarilyUnavailable
    case cancelled
}

struct PlaybackSessionRestorePlan: Equatable, Sendable {
    let snapshot: PlaybackSessionSnapshot
    let presentation: PlaybackSessionPresentation
}

enum PlaybackSessionPersistenceFailure: Equatable, Sendable {
    case saveFailed
    case clearFailed
}

struct PlaybackSessionPersistencePolicy: Sendable {
    let stateChangeCoalescingDelay: Duration
    let minimumSnapshotSaveInterval: Duration
    let progressSaveDelay: Duration
    let failureRetryDelay: Duration

    /// Queue/progress recovery is checkpointed at most twice per minute. A
    /// short window still folds notifications emitted by one state change.
    static let production = PlaybackSessionPersistencePolicy(
        stateChangeCoalescingDelay: .milliseconds(500),
        minimumSnapshotSaveInterval: .seconds(30),
        progressSaveDelay: .seconds(60),
        failureRetryDelay: .seconds(30)
    )

    static let immediate = PlaybackSessionPersistencePolicy(
        stateChangeCoalescingDelay: .zero,
        minimumSnapshotSaveInterval: .zero,
        progressSaveDelay: .zero,
        // Zero disables automatic retries so deterministic callers cannot
        // create a tight failure loop.
        failureRetryDelay: .zero
    )
}

@MainActor
final class PlaybackSessionController: ObservableObject {
    private enum PersistenceUrgency: Int {
        case progress
        case queueChange
        case stateChange
        case immediate
    }

    @Published private(set) var persistenceFailure:
        PlaybackSessionPersistenceFailure?

    var isRestoring: Bool {
        restoreInProgress
    }

    var hasDeferredRestorePlan: Bool {
        deferredRestorePlan != nil
    }

    private let playback: PlaybackCoordinator
    private let library: MediaLibraryCoordinator
    private let desktopSession: DesktopSessionCoordinator
    private let store: any PlaybackSessionStoring
    private let restorer: PlaybackStateRestorer
    private let persistencePolicy: PlaybackSessionPersistencePolicy
    private let persistenceClock = ContinuousClock()

    private var restoreInProgress = false
    private var shouldPreserveStoredSnapshot = true
    private var persistenceGeneration: UInt64 = 0
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskGeneration: UInt64?
    private var persistenceTaskUrgency: PersistenceUrgency?
    private var pendingPersistenceUrgency: PersistenceUrgency?
    private var lastSnapshotSaveInstant: ContinuousClock.Instant?
    private var retryNotBefore: ContinuousClock.Instant?
    private var blockedQueueStructureRevision: UInt64?
    private var restorationSourceSnapshot: PlaybackSessionSnapshot?
    private var deferredRestorePlan: PlaybackSessionRestorePlan?
    private var isShuttingDown = false
    private var cancellables: Set<AnyCancellable> = []

#if DEBUG
    private(set) var queueSnapshotConstructionCount = 0
#endif

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        desktopSession: DesktopSessionCoordinator,
        store: any PlaybackSessionStoring,
        persistencePolicy: PlaybackSessionPersistencePolicy = .production
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
        observeSessionChanges()
    }

    func makeRestorePlan(
        overridingPresentation presentationOverride:
            PlaybackSessionPresentation? = nil
    ) async -> PlaybackSessionPlanResult {
        guard !isShuttingDown, !Task.isCancelled else {
            return .cancelled
        }

        await cancelPendingPersistence()
        guard !isShuttingDown, !Task.isCancelled else {
            return .cancelled
        }
        deferredRestorePlan = nil
        restoreInProgress = true

        do {
            guard let snapshot = try await store.load() else {
                restorationSourceSnapshot = nil
                restoreInProgress = false
                shouldPreserveStoredSnapshot = false
                return .noSnapshot
            }
            guard snapshot.isValid else {
                await invalidateStoredSnapshot()
                restoreInProgress = false
                return .invalidSnapshot
            }
            restorationSourceSnapshot = snapshot
            guard !Task.isCancelled else {
                shouldPreserveStoredSnapshot = true
                restoreInProgress = false
                return .cancelled
            }

            shouldPreserveStoredSnapshot = true
            return .restore(
                PlaybackSessionRestorePlan(
                    snapshot: snapshot,
                    presentation:
                        presentationOverride ?? snapshot.presentation
                )
            )
        } catch is PlaybackSessionStoreError {
            // Typed store errors describe permanently invalid persisted
            // content, including byte/count limits. I/O errors remain on the
            // generic temporary path below so last-known-good data is kept.
            await invalidateStoredSnapshot()
            restoreInProgress = false
            return .invalidSnapshot
        } catch is DecodingError {
            await invalidateStoredSnapshot()
            restoreInProgress = false
            return .invalidSnapshot
        } catch {
            shouldPreserveStoredSnapshot = true
            restoreInProgress = false
            return Task.isCancelled ? .cancelled : .temporarilyUnavailable
        }
    }

    func restore(
        _ plan: PlaybackSessionRestorePlan,
        after libraryStart: MediaLibraryStartDisposition
    ) async -> PlaybackStateRestoreResult {
        guard restoreInProgress, !isShuttingDown else {
            return .cancelled
        }

        let target: PlaybackStateRestoreTarget =
            plan.presentation == .desktop ? .desktop : .player
        let result = await restorer.restore(
            plan.snapshot.state,
            after: libraryStart,
            target: target
        )

        switch result {
        case .restored:
            deferredRestorePlan = nil
            shouldPreserveStoredSnapshot = false
            restoreInProgress = false
            scheduleSave(urgency: .immediate)
        case .cancelled:
            shouldPreserveStoredSnapshot = true
            restoreInProgress = false
        case .temporarilyUnavailable:
            deferredRestorePlan = plan
            shouldPreserveStoredSnapshot = true
            restoreInProgress = false
        case .permanentlyUnavailable:
            deferredRestorePlan = nil
            shouldPreserveStoredSnapshot = false
            restoreInProgress = false
            await invalidateStoredSnapshot()
        }
        return result
    }

    func resumeDeferredRestore(
        after libraryStart: MediaLibraryStartDisposition,
        overridingPresentation presentationOverride:
            PlaybackSessionPresentation? = nil
    ) async -> PlaybackStateRestoreResult {
        guard !restoreInProgress,
              !isShuttingDown,
              !Task.isCancelled,
              let deferredRestorePlan else {
            return .cancelled
        }
        let plan = PlaybackSessionRestorePlan(
            snapshot: deferredRestorePlan.snapshot,
            presentation:
                presentationOverride ?? deferredRestorePlan.presentation
        )
        restorationSourceSnapshot = plan.snapshot
        restoreInProgress = true
        shouldPreserveStoredSnapshot = true

        await cancelPendingPersistence()
        guard !isShuttingDown, !Task.isCancelled else {
            restoreInProgress = false
            return .cancelled
        }
        return await restore(plan, after: libraryStart)
    }

    func preserveStoredSnapshotWhileCancellingRestore() {
        guard restoreInProgress else {
            return
        }
        shouldPreserveStoredSnapshot = true
    }

    func finishCancelledRestoreIfNeeded() {
        guard restoreInProgress else {
            return
        }
        shouldPreserveStoredSnapshot = true
        restoreInProgress = false
    }

    func beginExternalRestore() {
        guard !isShuttingDown, !restoreInProgress else {
            return
        }
        restoreInProgress = true
        shouldPreserveStoredSnapshot = true
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
    }

    func finishExternalRestore(commitCurrentState: Bool) {
        guard restoreInProgress else {
            return
        }
        restoreInProgress = false
        guard commitCurrentState else {
            shouldPreserveStoredSnapshot = true
            return
        }
        shouldPreserveStoredSnapshot = false
        scheduleSave(urgency: .immediate)
    }

    func preserveCurrentSnapshot() {
        guard !restoreInProgress,
              !shouldPreserveStoredSnapshot,
              !library.isExternalPlaybackContext else {
            return
        }
        scheduleSave(urgency: .immediate)
    }

    func adoptPlayerPresentationAfterCancelledRestore() async {
        guard !isShuttingDown,
              !restoreInProgress,
              !library.isExternalPlaybackContext else {
            return
        }
        deferredRestorePlan = nil
        await cancelPendingPersistence()

        if library.hasActiveQueue,
           let sourceSnapshot = restorationSourceSnapshot {
            // Queue restoration may have completed before cancellation while
            // the final play/pause intent was still intentionally deferred.
            // Finish that last semantic step before adopting the player state.
            playback.setPlaybackIntent(
                sourceSnapshot.state.isPlaybackRequested
                    ? .playing
                    : .paused
            )
        }

        let currentSnapshot = makeSnapshot()
        let sourceSnapshot = currentSnapshot ?? restorationSourceSnapshot
        guard let sourceSnapshot else {
            return
        }
        let playerSnapshot = PlaybackSessionSnapshot(
            state: sourceSnapshot.state,
            presentation: .player
        )
        _ = await save(playerSnapshot)

        // A live queue can become the new truth and retry a failed save at
        // shutdown. Without one, preserve the player-adjusted source snapshot
        // instead of clearing it because the cancelled queue is empty.
        shouldPreserveStoredSnapshot = currentSnapshot == nil
    }

    func prepareForShutdown() async {
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        await cancelPendingPersistence()

        guard !library.isExternalPlaybackContext,
              !restoreInProgress,
              !shouldPreserveStoredSnapshot else {
            return
        }
        guard let snapshot = makeSnapshot() else {
            await clearStoredSnapshot()
            return
        }
        await save(snapshot, forceWrite: true)
    }

    private func observeSessionChanges() {
        library.$isExternalPlaybackContext
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isExternalPlaybackContext in
                self?.handleExternalPlaybackContextChange(
                    isExternalPlaybackContext
                )
            }
            .store(in: &cancellables)

        library.$queueRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.handleQueueRevision()
            }
            .store(in: &cancellables)

        library.$queueStructureRevision
            .dropFirst()
            .sink { [weak self] revision in
                self?.synchronizeSnapshot(
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
                .eraseToAnyPublisher(),
            desktopSession.$isActive
                .removeDuplicates()
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher()
        ])
        .sink { [weak self] in
            self?.synchronizeSnapshot(urgency: .stateChange)
        }
        .store(in: &cancellables)

        playback.$currentTime
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleProgressSaveIfNeeded()
            }
        .store(in: &cancellables)
    }

    private func handleQueueRevision() {
        guard !isShuttingDown,
              !restoreInProgress,
              !library.isExternalPlaybackContext else {
            return
        }
        // A real queue mutation means the current process has replaced any
        // temporarily unavailable session and can become the new truth.
        deferredRestorePlan = nil
        shouldPreserveStoredSnapshot = false
        synchronizeSnapshot(urgency: .queueChange)
    }

    private func synchronizeSnapshot(
        urgency: PersistenceUrgency,
        observedQueueStructureRevision: UInt64? = nil
    ) {
        guard !isShuttingDown,
              !restoreInProgress,
              !shouldPreserveStoredSnapshot,
              !library.isExternalPlaybackContext else {
            return
        }
        guard library.hasActiveQueue else {
            scheduleClear()
            return
        }

        scheduleSave(
            urgency: urgency,
            observedQueueStructureRevision: observedQueueStructureRevision
        )
    }

    private func scheduleProgressSaveIfNeeded() {
        guard !isShuttingDown,
              !restoreInProgress,
              !shouldPreserveStoredSnapshot,
              !library.isExternalPlaybackContext else {
            return
        }
        scheduleSave(urgency: .progress)
    }

    private func scheduleSave(
        urgency: PersistenceUrgency,
        observedQueueStructureRevision: UInt64? = nil
    ) {
        guard !isShuttingDown,
              !restoreInProgress,
              !library.isExternalPlaybackContext,
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
                  generation == persistenceGeneration,
                  !library.isExternalPlaybackContext else {
                return
            }
            pendingPersistenceUrgency = nil
            let queueStructureRevisionAtSnapshot =
                library.queueStructureRevision
            guard let snapshot = makeSnapshot() else {
                return
            }
            _ = await save(
                snapshot,
                queueStructureRevisionAtSnapshot:
                    queueStructureRevisionAtSnapshot,
                expectedGeneration: generation
            )
        }
    }

    private func scheduleClear() {
        guard !isShuttingDown,
              !library.isExternalPlaybackContext else {
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
                  generation == persistenceGeneration,
                  !library.isExternalPlaybackContext else {
                return
            }
            await clearStoredSnapshot(expectedGeneration: generation)
        }
    }

    private func cancelPendingPersistence() async {
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
        await previousTask?.value
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
            synchronizeSnapshot(urgency: pendingUrgency)
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

    private func handleExternalPlaybackContextChange(
        _ isExternalPlaybackContext: Bool
    ) {
        guard isExternalPlaybackContext, !isShuttingDown else {
            return
        }
        shouldPreserveStoredSnapshot = true
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        persistenceTaskUrgency = nil
        pendingPersistenceUrgency = nil
    }

    @discardableResult
    private func save(
        _ snapshot: PlaybackSessionSnapshot,
        queueStructureRevisionAtSnapshot: UInt64? = nil,
        expectedGeneration: UInt64? = nil,
        forceWrite: Bool = false
    ) async -> Bool {
        guard !library.isExternalPlaybackContext else {
            return false
        }
        let attemptedQueueStructureRevision =
            queueStructureRevisionAtSnapshot ?? library.queueStructureRevision
        if !forceWrite, snapshot == restorationSourceSnapshot {
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
            try await store.save(snapshot)
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            restorationSourceSnapshot = snapshot
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
            // Atomic replacement leaves the last-known-good snapshot intact.
            persistenceFailure = .saveFailed
            let shouldRetry = registerSaveFailure(
                error,
                attemptedQueueStructureRevision:
                    attemptedQueueStructureRevision
            )
            if shouldRetry, expectedGeneration != nil {
                retainPendingPersistenceUrgency(.stateChange)
            }
            return false
        }
    }

    private func invalidateStoredSnapshot() async {
        shouldPreserveStoredSnapshot = false
        await cancelPendingPersistence()
        await clearStoredSnapshot()
    }

    private func clearStoredSnapshot(
        expectedGeneration: UInt64? = nil
    ) async {
        do {
            try await store.clear()
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return
            }
            restorationSourceSnapshot = nil
            persistenceFailure = nil
            lastSnapshotSaveInstant = nil
            retryNotBefore = nil
            blockedQueueStructureRevision = nil
        } catch {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return
            }
            persistenceFailure = .clearFailed
        }
    }

    private func makeSnapshot() -> PlaybackSessionSnapshot? {
        guard !library.isExternalPlaybackContext else {
            return nil
        }
#if DEBUG
        queueSnapshotConstructionCount += 1
#endif
        guard let queue = library.makeQueueSnapshot() else {
            return nil
        }
        let state = DesktopPreset(
            queue: queue,
            currentTime: playback.currentTime,
            isPlaybackRequested: playback.isPlaybackRequested,
            playbackRate: playback.settings.rate,
            videoContentMode: desktopSession.videoContentMode
        )
        return PlaybackSessionSnapshot(
            state: state,
            presentation: currentPresentation
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
        switch error as? PlaybackSessionStoreError {
        case .fileTooLarge?, .queueLimitExceeded?:
            // Progress and rate changes cannot make an oversized queue valid.
            // A queue mutation (or shutdown flush) is the next useful retry.
            blockedQueueStructureRevision = attemptedQueueStructureRevision
            retryNotBefore = nil
            return false
        case .invalidSnapshot?, nil:
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

    private var currentPresentation: PlaybackSessionPresentation {
        switch playback.presentation {
        case .switching(_, destination: .desktop):
            return .desktop
        case .switching(_, destination: .player):
            return .player
        case .desktop:
            return .desktop
        case .player, .terminating:
            return desktopSession.isActive ? .desktop : .player
        }
    }
}
