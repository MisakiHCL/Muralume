import Foundation

private enum DesktopLoopPlaybackPolicy {
    /// Display reconfiguration can take longer than a normal surface swap.
    /// Keep the deferred connection alive, but never wait forever on a
    /// permanently black hot-plugged display.
    static let deferredSurfaceReadyTimeoutNanoseconds: UInt64 =
        8_000_000_000
}

enum DesktopLoopPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed(PlaybackFailure)
    case terminating
}

@MainActor
final class DesktopLoopPlaybackNode {
    var stateDidChangeHandler: ((DesktopLoopPlaybackState) -> Void)?

    private(set) var state: DesktopLoopPlaybackState = .idle {
        didSet {
            guard state != oldValue else {
                return
            }
            stateDidChangeHandler?(state)
        }
    }

    private let engine: any PlaybackEngine
    private var gate = PlaybackGate()
    private var rate: PlaybackRate
    private var loadTask: Task<Void, Never>?
    private var cancelledLoadTasks: [Task<Void, Never>] = []
    private var generation: UInt64 = 0
    private var isReady = false
    private var isShutDown = false

    init(
        engine: any PlaybackEngine,
        initialRate: PlaybackRate = PlaybackPolicy.defaultRate,
        initialIntent: PlaybackIntent = .playing
    ) {
        self.engine = engine
        rate = initialRate
        gate.setIntent(initialIntent)
        configureEngineCallbacks()
        enforceDesktopAudioPolicy()
    }

    deinit {
        loadTask?.cancel()
        cancelledLoadTasks.forEach { $0.cancel() }
    }

    func start(
        source: ResolvedMediaSource,
        surface: any PlaybackRenderSurface,
        readinessPolicy: PlaybackSurfaceReadinessPolicy = .required
    ) {
        guard !isShutDown else {
            return
        }

        generation &+= 1
        let expectedGeneration = generation
        preserveAndCancelLoadTask()
        loadTask = nil
        isReady = false
        engine.stop()
        enforceDesktopAudioPolicy()
        state = .loading

        loadTask = Task { @MainActor [weak self, weak surface] in
            guard let self, let surface else {
                return
            }
            defer {
                if generation == expectedGeneration {
                    loadTask = nil
                }
            }

            do {
                _ = try await engine.load(source)
                try Task.checkCancellation()
                guard isCurrent(expectedGeneration) else {
                    return
                }
                // Muting must precede both attachment and any play request so
                // a newly created independent display can never emit audio.
                enforceDesktopAudioPolicy()
                try await engine.attach(
                    to: surface,
                    readinessPolicy: readinessPolicy
                )
                if readinessPolicy == .deferred {
                    try await waitForDeferredSurfaceReadiness(
                        surface,
                        expectedGeneration: expectedGeneration
                    )
                }
                try Task.checkCancellation()
                guard isCurrent(expectedGeneration) else {
                    return
                }
                isReady = true
                applyPlaybackGate()
            } catch is CancellationError {
                return
            } catch let error as PlaybackEngineError {
                guard isCurrent(expectedGeneration), error != .superseded else {
                    return
                }
                fail(with: mapFailure(error))
            } catch {
                guard isCurrent(expectedGeneration) else {
                    return
                }
                fail(with: .cannotOpen)
            }
        }
    }

    func setPlaybackIntent(_ intent: PlaybackIntent) {
        guard !isShutDown else {
            return
        }
        gate.setIntent(intent)
        applyPlaybackGate()
    }

    func setRate(_ rate: PlaybackRate) {
        guard !isShutDown, self.rate != rate else {
            return
        }
        self.rate = rate
        applyPlaybackGate()
    }

    func setSuspended(
        _ suspended: Bool,
        for reason: PlaybackSuspensionReason
    ) {
        guard !isShutDown, reason.scope != .playerOnly,
              gate.setSuspended(suspended, for: reason) else {
            return
        }
        applyPlaybackGate()
    }

    func stop() {
        guard !isShutDown else {
            return
        }
        generation &+= 1
        preserveAndCancelLoadTask()
        loadTask = nil
        isReady = false
        engine.stop()
        state = .idle
    }

    func shutdown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        generation &+= 1
        preserveAndCancelLoadTask()
        loadTask = nil
        isReady = false
        gate.terminate()
        state = .terminating
        engine.progressHandler = nil
        engine.itemEndedHandler = nil
        engine.failureHandler = nil
        engine.playbackActivityHandler = nil
        engine.stop()
        stateDidChangeHandler = nil
    }

    /// Stops the node immediately, then waits until any in-flight asset load
    /// or surface attachment has observed cancellation and fully unwound.
    /// Callers that are about to release a security scope must use this path.
    func stopAndDrain() async {
        shutdown()
        let tasksToDrain = cancelledLoadTasks
        for task in tasksToDrain {
            await task.value
        }
        cancelledLoadTasks.removeAll()
    }

    private func configureEngineCallbacks() {
        engine.progressHandler = nil
        engine.itemEndedHandler = { [weak self] in
            self?.restartAfterCompletion()
        }
        engine.failureHandler = { [weak self] error in
            guard error != .superseded else {
                return
            }
            self?.fail(with: self?.mapFailure(error) ?? .cannotOpen)
        }
        engine.playbackActivityHandler = { [weak self] _ in
            self?.publishReadyState()
        }
    }

    private func enforceDesktopAudioPolicy() {
        engine.setVolume(.muted)
        engine.setMuted(true)
        engine.setProgressCadence(.inactive)
    }

    private func applyPlaybackGate() {
        guard isReady else {
            engine.pause()
            return
        }

        enforceDesktopAudioPolicy()
        if gate.shouldPlay {
            engine.play(at: rate)
        } else {
            engine.pause()
        }
        publishReadyState()
    }

    private func publishReadyState() {
        guard isReady, !isShutDown else {
            return
        }
        state = gate.shouldPlay ? .playing : .paused
    }

    private func restartAfterCompletion() {
        guard isReady, !isShutDown else {
            return
        }
        engine.seek(to: 0, mode: .exact)
        applyPlaybackGate()
    }

    private func fail(with failure: PlaybackFailure) {
        guard !isShutDown,
              state != .idle,
              state != .terminating else {
            return
        }
        generation &+= 1
        preserveAndCancelLoadTask()
        loadTask = nil
        isReady = false
        engine.stop()
        state = .failed(failure)
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

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        !isShutDown && generation == expectedGeneration
    }

    private func waitForDeferredSurfaceReadiness(
        _ surface: any PlaybackRenderSurface,
        expectedGeneration: UInt64
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0
        while !surface.isReadyForDisplay {
            try Task.checkCancellation()
            guard isCurrent(expectedGeneration) else {
                throw PlaybackEngineError.superseded
            }
            guard elapsedNanoseconds
                    < DesktopLoopPlaybackPolicy
                        .deferredSurfaceReadyTimeoutNanoseconds else {
                throw PlaybackEngineError.surfaceTimeout
            }
            try await Task.sleep(
                nanoseconds: PlaybackPolicy.surfacePollIntervalNanoseconds
            )
            elapsedNanoseconds +=
                PlaybackPolicy.surfacePollIntervalNanoseconds
        }
    }

    private func preserveAndCancelLoadTask() {
        guard let loadTask else {
            return
        }
        loadTask.cancel()
        cancelledLoadTasks.append(loadTask)
    }
}
