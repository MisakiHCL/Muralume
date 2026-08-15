enum DesktopSmartPauseReason: Equatable, Sendable {
    case thermalPressure
    case lowBattery
    case lowPowerMode
    case limitedPowerSource
    case sustainedSystemLoad
    case desktopHidden
}

struct DesktopSmartPauseStatus: Equatable, Sendable {
    let primaryReason: DesktopSmartPauseReason
    let pausedDisplayCount: Int
    let enabledDisplayCount: Int
}

struct DesktopStatusState {
    let sourceName: String
    let isPlaying: Bool
    let isTransitioning: Bool
    let canPlayNext: Bool
    let playbackOrder: PlaybackOrder
    var playbackRepeatBehavior: PlaybackRepeatBehavior = .queue
    let canSetPlaybackOrder: Bool
    let playbackRate: PlaybackRate
    let videoContentMode: DesktopVideoContentMode
    var sceneMode: DesktopSceneMode = .synchronized
    var enabledDisplayCount: Int = 1
    var failedDisplayCount: Int = 0
    var smartPauseStatus: DesktopSmartPauseStatus?

    var playbackMode: PlaybackMode {
        PlaybackMode(
            order: playbackOrder,
            repeatBehavior: playbackRepeatBehavior
        )
    }
}

@MainActor
protocol DesktopStatusPresenting: AnyObject {
    var stateProvider: (() -> DesktopStatusState)? { get set }
    var togglePlaybackHandler: (() -> Void)? { get set }
    var playNextHandler: (() -> Void)? { get set }
    var setPlaybackOrderHandler: ((PlaybackOrder) -> Void)? { get set }
    var setPlaybackModeHandler: ((PlaybackMode) -> Void)? { get set }
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
