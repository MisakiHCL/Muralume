import Foundation

enum PlaybackEngineError: Error, Equatable {
    case unsupported
    case cannotOpen
    case surfaceTimeout
    case incompatibleSurface
    case superseded
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var progressHandler: ((TimeInterval) -> Void)? { get set }
    var itemEndedHandler: (() -> Void)? { get set }
    var failureHandler: ((PlaybackEngineError) -> Void)? { get set }
    var playbackActivityHandler: ((Bool) -> Void)? { get set }

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval
    func attach(to surface: any PlaybackRenderSurface) async throws
    func detachAll()
    func play(at rate: PlaybackRate)
    func pause()
    func seek(to seconds: TimeInterval)
    func setVolume(_ volume: PlaybackVolume)
    func setMuted(_ isMuted: Bool)
    func stop()
}
