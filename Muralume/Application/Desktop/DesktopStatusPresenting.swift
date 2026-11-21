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

struct DesktopQueueMenuState: Equatable, Sendable {
    struct Playlist: Equatable, Sendable {
        let id: CustomPlaylist.ID
        let name: String
        let isPlayable: Bool
    }

    static let empty = Self(isLibraryPlayable: false, playlists: [], selection: nil)

    let isLibraryPlayable: Bool
    let playlists: [Playlist]
    let selection: PlaybackCollection?

    func isPlayable(_ collection: PlaybackCollection) -> Bool {
        switch collection {
        case .mediaLibrary:
            isLibraryPlayable
        case let .customPlaylist(id):
            playlists.contains { $0.id == id && $0.isPlayable }
        case .fixed:
            false
        }
    }
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
    var desktopInteractionEffect: DesktopInteractionEffect = .off
    var queueMenu: DesktopQueueMenuState = .empty
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
    var selectQueueHandler: ((PlaybackCollection) -> Void)? { get set }
    var setPlaybackOrderHandler: ((PlaybackOrder) -> Void)? { get set }
    var setPlaybackModeHandler: ((PlaybackMode) -> Void)? { get set }
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)? { get set }
    var setDesktopInteractionEffectHandler: ((DesktopInteractionEffect) -> Void)? { get set }
    var returnToPlayerHandler: (() -> Void)? { get set }
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)? {
        get set
    }
    var quitHandler: (() -> Void)? { get set }

    @discardableResult
    func show() -> Bool
    func remove()
}
