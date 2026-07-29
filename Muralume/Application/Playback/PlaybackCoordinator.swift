import Combine
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    var playbackFailureHandler: ((PlaybackFailure) -> Void)?
    var itemEndedHandler: (() -> Bool)?
    var itemFailureHandler: ((PlaybackFailure) -> Bool)?

    @Published private(set) var source: ResolvedMediaSource?
    @Published private(set) var readiness: PlaybackReadiness = .empty
    @Published private(set) var presentation: PlaybackPresentation = .player
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isActuallyPlaying = false
    @Published private(set) var isPlaybackRequested = false
    @Published private(set) var settings = PlaybackSettings(
        volume: .full,
        isMuted: false,
        rate: PlaybackPolicy.defaultRate
    )

    var canPresentOnDesktop: Bool {
        readiness == .ready && presentation == .player
    }

    var isSystemSuspended: Bool {
        isDesktopPresentationRelevant && !gate.suspensionReasons.isEmpty
    }

    private let engine: any PlaybackEngine
    private var gate = PlaybackGate()
    private weak var playerSurface: (any PlaybackRenderSurface)?
    private var playerSurfaceAttachmentTask: Task<Void, Never>?
    private var savedPlayerSettings: PlaybackSettings?
    private var transitionGeneration: UInt64 = 0

    init(engine: any PlaybackEngine) {
        self.engine = engine
        engine.progressHandler = { [weak self] seconds in
            self?.currentTime = seconds
        }
        engine.itemEndedHandler = { [weak self] in
            self?.handleItemEnded()
        }
        engine.failureHandler = { [weak self] error in
            self?.handleEngineFailure(error)
        }
        engine.playbackActivityHandler = { [weak self] isPlaying in
            self?.isActuallyPlaying = isPlaying
        }
        applySettings(settings)
    }

    func registerPlayerSurface(_ surface: any PlaybackRenderSurface) {
        cancelPlayerSurfaceAttachment()
        playerSurface = surface
        guard presentation == .player, readiness == .ready else {
            return
        }
        let expectedGeneration = transitionGeneration

        playerSurfaceAttachmentTask = Task { [weak self] in
            guard let self,
                  presentation == .player,
                  readiness == .ready,
                  isCurrentPlayerSurface(surface),
                  transitionGeneration == expectedGeneration else {
                return
            }
            do {
                try await engine.attach(to: surface)
                try Task.checkCancellation()
                guard presentation == .player,
                      readiness == .ready,
                      isCurrentPlayerSurface(surface),
                      transitionGeneration == expectedGeneration else {
                    return
                }
            } catch is CancellationError {
                return
            } catch let error as PlaybackEngineError where error == .superseded {
                return
            } catch {
                guard presentation == .player,
                      transitionGeneration == expectedGeneration,
                      readiness == .ready else {
                    return
                }
                fail(with: .surfaceTimeout)
                playbackFailureHandler?(.surfaceTimeout)
            }
        }
    }

    @discardableResult
    func load(
        _ source: ResolvedMediaSource,
        autoplay: Bool = true
    ) async -> PlaybackLoadResult {
        guard presentation != .terminating else {
            return .cancelled
        }

        cancelPlayerSurfaceAttachment()
        self.source = source
        readiness = .loading
        currentTime = 0
        duration = 0

        let loadedDuration: TimeInterval
        do {
            loadedDuration = try await engine.load(source)
            try Task.checkCancellation()
        } catch let error as PlaybackEngineError {
            return handleLoadFailure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            failLoading(with: .cannotOpen)
            return .mediaFailure(.cannotOpen)
        }

        duration = loadedDuration
        if presentation == .player, let playerSurface {
            do {
                try await engine.attach(to: playerSurface)
                try Task.checkCancellation()
            } catch let error as PlaybackEngineError
                where error == .superseded {
                return .cancelled
            } catch is CancellationError {
                return .cancelled
            } catch let error as PlaybackEngineError {
                return handleGlobalLoadFailure(mapFailure(error))
            } catch {
                return handleGlobalLoadFailure(.surfaceTimeout)
            }
        }

        readiness = .ready
        gate.setIntent(autoplay ? .playing : .paused)
        isPlaybackRequested = autoplay
        applyPlaybackGate()
        return .loaded
    }

    func togglePlayback() {
        setPlaybackIntent(isPlaybackRequested ? .paused : .playing)
    }

    func setPlaybackIntent(_ intent: PlaybackIntent) {
        guard readiness == .ready else {
            return
        }
        gate.setIntent(intent)
        isPlaybackRequested = intent == .playing
        applyPlaybackGate()
    }

    func seek(to seconds: TimeInterval) {
        guard readiness == .ready else {
            return
        }
        let clampedSeconds = min(max(seconds, 0), duration)
        currentTime = clampedSeconds
        engine.seek(to: clampedSeconds)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setVolume(_ volume: PlaybackVolume) {
        settings.setVolume(volume)
        guard presentation == .player else {
            return
        }
        applySettings(settings)
    }

    func setMuted(_ isMuted: Bool) {
        settings.setMuted(isMuted)
        guard presentation == .player else {
            return
        }
        applySettings(settings)
    }

    func setRate(_ rate: PlaybackRate) {
        guard presentation != .terminating else {
            return
        }
        settings.rate = rate
        if savedPlayerSettings != nil {
            savedPlayerSettings?.rate = rate
        }
        applyPlaybackGate()
    }

    func transitionToDesktop(_ surface: any PlaybackRenderSurface) async throws {
        guard canPresentOnDesktop else {
            return
        }

        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        presentation = .switching(generation: generation, destination: .desktop)
        savedPlayerSettings = settings

        engine.setMuted(true)
        applyPlaybackGate()

        do {
            try await engine.attach(to: surface)
            try Task.checkCancellation()
            guard generation == transitionGeneration else {
                throw PlaybackEngineError.superseded
            }
            presentation = .desktop
            applyPlaybackGate()
        } catch {
            guard presentation != .terminating,
                  generation == transitionGeneration else {
                throw error
            }
            restorePlayerSettings()
            presentation = .player
            if let playerSurface {
                try? await engine.attach(to: playerSurface)
            }
            applyPlaybackGate()
            throw error
        }
    }

    func transitionToPlayer() async throws {
        guard presentation == .desktop || isSwitching(to: .desktop) else {
            return
        }
        guard let playerSurface else {
            throw PlaybackEngineError.surfaceTimeout
        }

        transitionGeneration &+= 1
        let generation = transitionGeneration
        presentation = .switching(generation: generation, destination: .player)

        do {
            try await engine.attach(to: playerSurface)
            try Task.checkCancellation()
            guard generation == transitionGeneration else {
                throw PlaybackEngineError.superseded
            }
            restorePlayerSettings()
            presentation = .player
            applyPlaybackGate()
        } catch {
            guard presentation != .terminating,
                  generation == transitionGeneration else {
                throw error
            }
            presentation = .desktop
            throw error
        }
    }

    func setSuspended(_ suspended: Bool, for reason: PlaybackSuspensionReason) {
        gate.setSuspended(suspended, for: reason)
        if isDesktopPresentationRelevant {
            applyPlaybackGate()
        }
    }

    func stop() {
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        source = nil
        readiness = .empty
        presentation = .player
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    func shutdown() {
        guard presentation != .terminating else {
            return
        }
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        presentation = .terminating
        gate.terminate()
        isActuallyPlaying = false
        isPlaybackRequested = false
        engine.stop()
        playerSurface = nil
        source = nil
    }

    func finishQueue(with failure: PlaybackFailure) {
        fail(with: failure)
        playbackFailureHandler?(failure)
    }

    private func applyPlaybackGate() {
        guard readiness == .ready else {
            engine.pause()
            isActuallyPlaying = false
            return
        }

        let shouldPlay = isDesktopPresentationRelevant
            ? gate.shouldPlay
            : gate.intent == .playing && !gate.isTerminating

        if shouldPlay {
            engine.play(at: settings.rate)
        } else {
            engine.pause()
            isActuallyPlaying = false
        }
    }

    private func applySettings(_ settings: PlaybackSettings) {
        engine.setVolume(settings.volume)
        engine.setMuted(settings.isMuted)
    }

    private func restorePlayerSettings() {
        guard let savedPlayerSettings else {
            applySettings(settings)
            return
        }
        settings = savedPlayerSettings
        applySettings(savedPlayerSettings)
        self.savedPlayerSettings = nil
    }

    private func handleItemEnded() {
        if itemEndedHandler?() == true {
            return
        }

        guard presentation == .desktop else {
            gate.setIntent(.paused)
            isPlaybackRequested = false
            engine.seek(to: 0)
            currentTime = 0
            applyPlaybackGate()
            return
        }

        engine.seek(to: 0)
        currentTime = 0
        applyPlaybackGate()
    }

    private func fail(with failure: PlaybackFailure) {
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        readiness = .failed(failure)
        presentation = .player
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    private func failLoading(with failure: PlaybackFailure) {
        gate.setIntent(.paused)
        engine.pause()
        readiness = .failed(failure)
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
    }

    private func handleEngineFailure(_ error: PlaybackEngineError) {
        let failure = mapFailure(error)
        if itemFailureHandler?(failure) == true {
            return
        }
        fail(with: failure)
        playbackFailureHandler?(failure)
    }

    private func handleLoadFailure(
        _ error: PlaybackEngineError
    ) -> PlaybackLoadResult {
        switch error {
        case .superseded:
            return .cancelled
        case .unsupported, .cannotOpen:
            let failure = mapFailure(error)
            failLoading(with: failure)
            return .mediaFailure(failure)
        case .surfaceTimeout, .incompatibleSurface:
            return handleGlobalLoadFailure(mapFailure(error))
        }
    }

    private func handleGlobalLoadFailure(
        _ failure: PlaybackFailure
    ) -> PlaybackLoadResult {
        fail(with: failure)
        playbackFailureHandler?(failure)
        return .globalFailure(failure)
    }

    private func mapFailure(_ error: PlaybackEngineError) -> PlaybackFailure {
        switch error {
        case .unsupported:
            .unsupported
        case .surfaceTimeout:
            .surfaceTimeout
        case .cannotOpen, .incompatibleSurface, .superseded:
            .cannotOpen
        }
    }

    private func isSwitching(to destination: PlaybackSurfaceID) -> Bool {
        guard case let .switching(_, currentDestination) = presentation else {
            return false
        }
        return currentDestination == destination
    }

    private func cancelPlayerSurfaceAttachment() {
        playerSurfaceAttachmentTask?.cancel()
        playerSurfaceAttachmentTask = nil
    }

    private func isCurrentPlayerSurface(
        _ surface: any PlaybackRenderSurface
    ) -> Bool {
        guard let playerSurface else {
            return false
        }
        return ObjectIdentifier(playerSurface) == ObjectIdentifier(surface)
    }

    private var isDesktopPresentationRelevant: Bool {
        switch presentation {
        case .desktop, .switching:
            true
        case .player, .terminating:
            false
        }
    }
}
