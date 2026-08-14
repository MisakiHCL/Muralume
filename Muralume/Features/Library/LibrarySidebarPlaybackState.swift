struct LibraryPlaybackStatus: Equatable {
    let rowState: LibraryMediaRowPlaybackState

    @MainActor
    init(playback: PlaybackCoordinator) {
        self.init(
            readiness: playback.readiness,
            isPlaybackRequested: playback.isPlaybackRequested,
            hasPlayableMedia: playback.hasPlayableMedia
        )
    }

    init(
        readiness: PlaybackReadiness,
        isPlaybackRequested: Bool,
        hasPlayableMedia: Bool
    ) {
        if hasPlayableMedia {
            rowState = isPlaybackRequested ? .playing : .paused
            return
        }

        switch readiness {
        case .loading:
            rowState = .loading
        case .ready:
            rowState = isPlaybackRequested ? .playing : .paused
        case .empty, .failed:
            rowState = .paused
        }
    }
}
