import Foundation

enum PlaybackEngineError: Error, Equatable {
    case unsupported
    case cannotOpen
    case surfaceTimeout
    case incompatibleSurface
    case superseded
}

enum PlaybackProgressCadence: Equatable, Sendable {
    case inactive
    case background
    case visible
}

enum PlaybackSeekMode: Equatable, Sendable {
    case interactive
    case exact
}

enum PlaybackSurfaceReadinessPolicy: Equatable, Sendable {
    /// Attaching is not complete until the surface has rendered a frame.
    case required
    /// Keep the player connected and let the presentation owner reveal the
    /// surface whenever its first frame eventually arrives.
    case deferred
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var progressHandler: ((TimeInterval) -> Void)? { get set }
    var itemEndedHandler: (() -> Void)? { get set }
    var failureHandler: ((PlaybackEngineError) -> Void)? { get set }
    var playbackActivityHandler: ((Bool) -> Void)? { get set }

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval
    func attach(to surface: any PlaybackRenderSurface) async throws
    func attach(
        to surface: any PlaybackRenderSurface,
        readinessPolicy: PlaybackSurfaceReadinessPolicy
    ) async throws
    func detachAll()
    func play(at rate: PlaybackRate)
    func pause()
    func seek(to seconds: TimeInterval)
    func seek(to seconds: TimeInterval, mode: PlaybackSeekMode)
    func setProgressCadence(_ cadence: PlaybackProgressCadence)
    func setVolume(_ volume: PlaybackVolume)
    func setMuted(_ isMuted: Bool)
    func currentMediaSelectionState() -> PlaybackMediaSelectionState
    func selectAudio(
        _ selection: PlaybackAudioSelection
    ) -> PlaybackMediaSelectionState
    func selectSubtitles(
        _ selection: PlaybackSubtitleSelection
    ) -> PlaybackMediaSelectionState
    func stop()
}

extension PlaybackEngine {
    func attach(
        to surface: any PlaybackRenderSurface,
        readinessPolicy _: PlaybackSurfaceReadinessPolicy
    ) async throws {
        try await attach(to: surface)
    }

    func seek(to seconds: TimeInterval, mode _: PlaybackSeekMode) {
        seek(to: seconds)
    }

    func setProgressCadence(_: PlaybackProgressCadence) {}

    func currentMediaSelectionState() -> PlaybackMediaSelectionState {
        .empty
    }

    func selectAudio(
        _: PlaybackAudioSelection
    ) -> PlaybackMediaSelectionState {
        currentMediaSelectionState()
    }

    func selectSubtitles(
        _: PlaybackSubtitleSelection
    ) -> PlaybackMediaSelectionState {
        currentMediaSelectionState()
    }
}

@MainActor
final class PlaybackSeekCoalescer {
    typealias Completion = @Sendable () -> Void
    typealias Performer = (
        TimeInterval,
        PlaybackSeekMode,
        @escaping Completion
    ) -> Void

    private let performer: Performer
    private var pendingInteractiveTarget: TimeInterval?
    private var isInteractiveSeekInFlight = false
    private var generation: UInt64 = 0

    init(performer: @escaping Performer) {
        self.performer = performer
    }

    func seek(to seconds: TimeInterval, mode: PlaybackSeekMode) {
        let target = max(seconds, 0)
        switch mode {
        case .interactive:
            pendingInteractiveTarget = target
            performNextInteractiveSeekIfNeeded()
        case .exact:
            invalidate()
            performer(target, .exact) {}
        }
    }

    func invalidate() {
        generation &+= 1
        pendingInteractiveTarget = nil
        isInteractiveSeekInFlight = false
    }

    private func performNextInteractiveSeekIfNeeded() {
        guard !isInteractiveSeekInFlight,
              let target = pendingInteractiveTarget else {
            return
        }

        pendingInteractiveTarget = nil
        isInteractiveSeekInFlight = true
        let expectedGeneration = generation
        performer(target, .interactive) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == expectedGeneration else {
                    return
                }
                isInteractiveSeekInFlight = false
                performNextInteractiveSeekIfNeeded()
            }
        }
    }
}
