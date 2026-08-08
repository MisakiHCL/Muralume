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

@MainActor
final class DesktopPresetController: ObservableObject {
    private enum PersistencePolicy {
        static let progressSaveDelay: Duration = .seconds(60)
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

    private var automaticRestorePreparationState:
        AutomaticRestorePreparationState = .unreconciled
    private var isAutomaticRestorePrepared: Bool {
        automaticRestorePreparationState == .prepared
    }
    private var shouldPreserveStoredPreset = false
    private var persistenceGeneration: UInt64 = 0
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskGeneration: UInt64?
    private var lastCommittedPreset: DesktopPreset?
    private var isExternalRestoreInProgress = false
    private var isShuttingDown = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        desktopSession: DesktopSessionCoordinator,
        store: any DesktopPresetStoring
    ) {
        self.playback = playback
        self.library = library
        self.desktopSession = desktopSession
        self.store = store
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
            scheduleSave(delay: nil)
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
        scheduleSave(delay: nil)
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
        synchronizePreset()
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
            guard let preset = makePreset() else {
                shouldPreserveStoredPreset = true
                return
            }
            shouldPreserveStoredPreset = false
            if preset != lastCommittedPreset {
                scheduleSave(delay: nil)
            }
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
        await previousTask?.value

        guard !isShuttingDown, !Task.isCancelled else {
            return .persistenceFailed
        }
        guard let preset = makePreset() else {
            return .noActiveQueue
        }

        do {
            try await store.save(preset)
            lastCommittedPreset = preset
            persistenceFailure = nil
            automaticRestoreInvalidation = nil
            return .prepared
        } catch {
            await failClosedAfterSaveFailure()
            return .persistenceFailed
        }
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
        scheduleSave(delay: nil)
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
        guard let preset = makePreset() else {
            await clearStoredPreset()
            return
        }
        do {
            try await store.save(preset)
            lastCommittedPreset = preset
            persistenceFailure = nil
        } catch {
            await failClosedAfterSaveFailure()
        }
    }

    private func observePresetChanges() {
        Publishers.MergeMany([
            library.$queueRevision
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
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
            self?.synchronizePreset()
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
              !isBootstrapping,
              persistenceTask == nil else {
            return
        }
        scheduleSave(delay: PersistencePolicy.progressSaveDelay)
    }

    private func scheduleSave(delay: Duration?) {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isExternalRestoreInProgress,
              !isBootstrapping,
              makePreset() != nil else {
            return
        }

        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        previousTask?.cancel()

        persistenceTaskGeneration = generation
        persistenceTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishPersistenceTask(generation: generation)
            }
            await previousTask?.value
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled,
                  generation == persistenceGeneration,
                  let preset = makePreset() else {
                return
            }
            do {
                try await store.save(preset)
                guard !Task.isCancelled,
                      generation == persistenceGeneration else {
                    return
                }
                lastCommittedPreset = preset
                persistenceFailure = nil
            } catch {
                guard !Task.isCancelled,
                      generation == persistenceGeneration else {
                    return
                }
                await failClosedAfterSaveFailure(
                    expectedGeneration: generation
                )
            }
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
    }

    private func synchronizePreset() {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isExternalRestoreInProgress,
              !isBootstrapping else {
            return
        }
        if makePreset() == nil {
            guard !shouldPreserveStoredPreset else {
                return
            }
            automaticRestoreInvalidation = .noActiveQueue
            scheduleClear()
        } else {
            shouldPreserveStoredPreset = false
            automaticRestoreInvalidation = nil
            scheduleSave(delay: nil)
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
        await previousTask?.value
        await clearStoredPreset()
        automaticRestoreInvalidation = reason
    }

    private func clearStoredPreset() async {
        do {
            try await store.clear()
            lastCommittedPreset = nil
            persistenceFailure = nil
        } catch {
            persistenceFailure = .clearFailed
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
}
