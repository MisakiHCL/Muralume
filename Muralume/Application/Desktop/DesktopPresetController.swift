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

    private var isAutomaticRestorePrepared = false
    private var hasReconciledAutomaticRestorePreparation = false
    private var shouldPreserveStoredPreset = false
    private var persistenceGeneration: UInt64 = 0
    private var persistenceTask: Task<Void, Never>?
    private var lastCommittedPreset: DesktopPreset?
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
        } catch DesktopPresetStoreError.invalidPreset {
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

        guard !Task.isCancelled else {
            bootstrapState = .cancelled
            return false
        }
        let scanState = await library.waitForStartupScan(
            after: libraryStart
        )
        guard !Task.isCancelled else {
            bootstrapState = .cancelled
            return false
        }
        guard scanState == .ready else {
            if case .noRestorableRoots(
                hasTemporarilyUnavailableRoots: false
            ) = libraryStart {
                await invalidateStoredPreset(
                    reason: .permanentlyUnavailable
                )
            }
            bootstrapState = .failed
            return false
        }

        bootstrapState = .preparingPlayback
        guard let playbackRate = preset.playbackRate else {
            await invalidateStoredPreset(reason: .invalidPreset)
            bootstrapState = .failed
            return false
        }
        let queueRestoreResult = await library.restoreQueue(from: preset.queue)
        guard !Task.isCancelled else {
            bootstrapState = .cancelled
            return false
        }
        switch queueRestoreResult {
        case .restored:
            break
        case .cancelled:
            bootstrapState = .cancelled
            return false
        case .temporarilyUnavailable:
            bootstrapState = .failed
            return false
        case .permanentlyUnavailable:
            await invalidateStoredPreset(reason: .permanentlyUnavailable)
            bootstrapState = .failed
            return false
        }

        guard !Task.isCancelled else {
            bootstrapState = Task.isCancelled ? .cancelled : .failed
            return false
        }

        playback.setRate(playbackRate)
        playback.seek(to: preset.currentTime)
        desktopSession.setVideoContentMode(preset.videoContentMode)

        guard !Task.isCancelled else {
            bootstrapState = .cancelled
            return false
        }
        bootstrapState = .enteringDesktop
        guard await desktopSession.enterDesktopAndWait(),
              !Task.isCancelled else {
            bootstrapState = Task.isCancelled ? .cancelled : .failed
            return false
        }

        playback.setPlaybackIntent(
            preset.isPlaybackRequested ? .playing : .paused
        )
        shouldPreserveStoredPreset = false
        automaticRestoreInvalidation = nil
        bootstrapState = .active
        scheduleSave(delay: nil)
        return true
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

    func setAutomaticRestorePrepared(_ isPrepared: Bool) {
        guard !isShuttingDown else {
            return
        }
        let needsInitialReconciliation =
            !hasReconciledAutomaticRestorePreparation
        guard needsInitialReconciliation
                || isAutomaticRestorePrepared != isPrepared else {
            return
        }
        hasReconciledAutomaticRestorePreparation = true
        isAutomaticRestorePrepared = isPrepared
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

    func prepareAutomaticRestore() async ->
        DesktopPresetPreparationResult {
        guard !isShuttingDown, !Task.isCancelled else {
            return .persistenceFailed
        }
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
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
        await previousTask?.value

        guard isAutomaticRestorePrepared else {
            await clearStoredPreset()
            return
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
              !isBootstrapping,
              persistenceTask == nil else {
            return
        }
        scheduleSave(delay: PersistencePolicy.progressSaveDelay)
    }

    private func scheduleSave(delay: Duration?) {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
              !isBootstrapping,
              makePreset() != nil else {
            return
        }

        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let previousTask = persistenceTask
        previousTask?.cancel()

        persistenceTask = Task { [weak self] in
            await previousTask?.value
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled,
                  let self,
                  generation == persistenceGeneration,
                  let preset = makePreset() else {
                return
            }
            do {
                try await store.save(preset)
                lastCommittedPreset = preset
                persistenceFailure = nil
            } catch {
                await failClosedAfterSaveFailure()
            }
            guard generation == persistenceGeneration else {
                return
            }
            persistenceTask = nil
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

        persistenceTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled,
                  let self,
                  generation == persistenceGeneration else {
                return
            }
            await clearStoredPreset()
            guard generation == persistenceGeneration else {
                return
            }
            persistenceTask = nil
        }
    }

    private func synchronizePreset() {
        guard !isShuttingDown,
              isAutomaticRestorePrepared,
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

    private func failClosedAfterSaveFailure() async {
        lastCommittedPreset = nil
        do {
            try await store.clear()
            persistenceFailure = .saveFailed
        } catch {
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
