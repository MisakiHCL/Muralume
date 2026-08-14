import Foundation

enum PlaybackStateRestoreTarget: Equatable, Sendable {
    case player
    case desktop
}

enum PlaybackStateRestorePhase: Equatable, Sendable {
    case restoringLibrary
    case preparingPlayback
    case enteringDesktop
}

enum PlaybackStateRestoreResult: Equatable, Sendable {
    case restored
    case cancelled
    case temporarilyUnavailable
    case permanentlyUnavailable
}

@MainActor
struct PlaybackStateRestorer {
    typealias PhaseHandler = @MainActor (PlaybackStateRestorePhase) -> Void

    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let desktopSession: DesktopSessionCoordinator

    func restore(
        _ state: DesktopPreset,
        after libraryStart: MediaLibraryStartDisposition,
        target: PlaybackStateRestoreTarget,
        phaseHandler: PhaseHandler = { _ in }
    ) async -> PlaybackStateRestoreResult {
        guard state.isValid, let playbackRate = state.playbackRate else {
            return .permanentlyUnavailable
        }
        guard !Task.isCancelled else {
            return .cancelled
        }

        phaseHandler(.restoringLibrary)
        let scanState = await library.waitForStartupScan(after: libraryStart)
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard scanState == .ready else {
            if case .noRestorableRoots(
                hasTemporarilyUnavailableRoots: false
            ) = libraryStart {
                return .permanentlyUnavailable
            }
            return .temporarilyUnavailable
        }

        phaseHandler(.preparingPlayback)
        let queueRestoreResult = await library.restoreQueue(
            from: state.queue,
            playbackCollection: state.playbackCollection,
            queueMediaReferences: state.queueMediaReferences,
            attachToPlayerSurface: target == .player
        )
        guard !Task.isCancelled else {
            return .cancelled
        }
        switch queueRestoreResult {
        case .restored:
            break
        case .cancelled:
            return .cancelled
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .permanentlyUnavailable:
            return .permanentlyUnavailable
        }

        playback.setRate(playbackRate)
        playback.seek(to: state.currentTime)
        desktopSession.applyLegacyContentModeIfNeeded(
            state.videoContentMode
        )

        guard !Task.isCancelled else {
            return .cancelled
        }
        if target == .desktop {
            phaseHandler(.enteringDesktop)
            guard await desktopSession.enterDesktopAndWait() else {
                return Task.isCancelled
                    ? .cancelled
                    : .temporarilyUnavailable
            }
        } else {
            playback.restorePlayerWindow()
        }

        guard !Task.isCancelled else {
            return .cancelled
        }
        playback.setPlaybackIntent(
            state.isPlaybackRequested ? .playing : .paused
        )
        return .restored
    }
}
