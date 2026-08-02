struct DesktopStatusState {
    let sourceName: String
    let isPlaying: Bool
    let isTransitioning: Bool
    let canPlayNext: Bool
    let playbackRate: PlaybackRate
    let videoContentMode: DesktopVideoContentMode
}

@MainActor
protocol DesktopStatusPresenting: AnyObject {
    var stateProvider: (() -> DesktopStatusState)? { get set }
    var togglePlaybackHandler: (() -> Void)? { get set }
    var playNextHandler: (() -> Void)? { get set }
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)? { get set }
    var returnToPlayerHandler: (() -> Void)? { get set }
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)? {
        get set
    }
    var quitHandler: (() -> Void)? { get set }

    @discardableResult
    func show() -> Bool
    func remove()
}
