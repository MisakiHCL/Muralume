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

@MainActor
final class PlaybackSessionController: ObservableObject {
    private enum PersistencePolicy {
        static let progressSaveDelay: Duration = .seconds(60)
    }

    @Published private(set) var persistenceFailure:
        PlaybackSessionPersistenceFailure?

    var isRestoring: Bool {
        restoreInProgress
    }

    private let playback: PlaybackCoordinator
    private let library: MediaLibraryCoordinator
    private let desktopSession: DesktopSessionCoordinator
    private let store: any PlaybackSessionStoring
    private let restorer: PlaybackStateRestorer

    private var restoreInProgress = false
    private var shouldPreserveStoredSnapshot = true
    private var persistenceGeneration: UInt64 = 0
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskGeneration: UInt64?
    private var restorationSourceSnapshot: PlaybackSessionSnapshot?
    private var isShuttingDown = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        desktopSession: DesktopSessionCoordinator,
        store: any PlaybackSessionStoring
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
        } catch PlaybackSessionStoreError.invalidSnapshot {
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
            shouldPreserveStoredSnapshot = false
            restoreInProgress = false
            scheduleSave(delay: nil)
        case .cancelled, .temporarilyUnavailable:
            shouldPreserveStoredSnapshot = true
            restoreInProgress = false
        case .permanentlyUnavailable:
            shouldPreserveStoredSnapshot = false
            restoreInProgress = false
            await invalidateStoredSnapshot()
        }
        return result
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
        scheduleSave(delay: nil)
    }

    func preserveCurrentSnapshot() {
        guard !restoreInProgress, !shouldPreserveStoredSnapshot else {
            return
        }
        scheduleSave(delay: nil)
    }

    func adoptPlayerPresentationAfterCancelledRestore() async {
        guard !isShuttingDown, !restoreInProgress else {
            return
        }
        await cancelPendingPersistence()

        if makeSnapshot() != nil,
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

        guard !restoreInProgress,
              !shouldPreserveStoredSnapshot else {
            return
        }
        guard let snapshot = makeSnapshot() else {
            await clearStoredSnapshot()
            return
        }
        await save(snapshot)
    }

    private func observeSessionChanges() {
        library.$queueRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.handleQueueRevision()
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
            self?.synchronizeSnapshot()
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
        guard !isShuttingDown, !restoreInProgress else {
            return
        }
        // A real queue mutation means the current process has replaced any
        // temporarily unavailable session and can become the new truth.
        shouldPreserveStoredSnapshot = false
        synchronizeSnapshot()
    }

    private func synchronizeSnapshot() {
        guard !isShuttingDown,
              !restoreInProgress,
              !shouldPreserveStoredSnapshot else {
            return
        }
        guard makeSnapshot() != nil else {
            scheduleClear()
            return
        }

        scheduleSave(delay: nil)
    }

    private func scheduleProgressSaveIfNeeded() {
        guard !isShuttingDown,
              !restoreInProgress,
              !shouldPreserveStoredSnapshot,
              persistenceTask == nil else {
            return
        }
        scheduleSave(delay: PersistencePolicy.progressSaveDelay)
    }

    private func scheduleSave(delay: Duration?) {
        guard !isShuttingDown,
              !restoreInProgress,
              makeSnapshot() != nil else {
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
                  let snapshot = makeSnapshot() else {
                return
            }
            _ = await save(snapshot, expectedGeneration: generation)
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
            await clearStoredSnapshot(expectedGeneration: generation)
        }
    }

    private func cancelPendingPersistence() async {
        persistenceGeneration &+= 1
        let previousTask = persistenceTask
        previousTask?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        await previousTask?.value
    }

    private func finishPersistenceTask(generation: UInt64) {
        guard persistenceTaskGeneration == generation else {
            return
        }
        persistenceTaskGeneration = nil
        persistenceTask = nil
    }

    @discardableResult
    private func save(
        _ snapshot: PlaybackSessionSnapshot,
        expectedGeneration: UInt64? = nil
    ) async -> Bool {
        do {
            try await store.save(snapshot)
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            restorationSourceSnapshot = snapshot
            persistenceFailure = nil
            return true
        } catch {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return false
            }
            // Atomic replacement leaves the last-known-good snapshot intact.
            persistenceFailure = .saveFailed
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
        } catch {
            guard expectedGeneration == nil
                    || expectedGeneration == persistenceGeneration else {
                return
            }
            persistenceFailure = .clearFailed
        }
    }

    private func makeSnapshot() -> PlaybackSessionSnapshot? {
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
