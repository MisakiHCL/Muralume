import AVFoundation
import Foundation

@MainActor
final class AVFoundationPlaybackEngine: PlaybackEngine {
    var progressHandler: ((TimeInterval) -> Void)? {
        didSet {
            refreshProgressObserver()
        }
    }
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)? {
        didSet {
            if playbackActivityHandler == nil {
                removeTimeControlObservation()
            } else {
                installTimeControlObservation()
            }
        }
    }

    private let player = AVPlayer()
    private weak var attachedSurface: (any AVPlayerRenderSurface)?
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var loadGeneration: UInt64 = 0
    private var surfaceGeneration: UInt64 = 0
    private var progressCadence: PlaybackProgressCadence = .inactive
    private lazy var seekCoalescer = PlaybackSeekCoalescer {
        [weak self] seconds, mode, completion in
        self?.performSeek(
            to: seconds,
            mode: mode,
            completion: completion
        )
    }

    init() {}

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        seekCoalescer.invalidate()
        player.currentItem?.cancelPendingSeeks()
        if progressHandler != nil {
            installProgressObserver()
        }
        if playbackActivityHandler != nil {
            installTimeControlObservation()
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        removeItemObservers()

        let asset = AVURLAsset(url: source.url)

        do {
            async let playable = asset.load(.isPlayable)
            async let duration = asset.load(.duration)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            let (isPlayable, assetDuration, tracks) = try await (playable, duration, videoTracks)

            try Task.checkCancellation()
            guard generation == loadGeneration else {
                throw PlaybackEngineError.superseded
            }
            guard isPlayable, !tracks.isEmpty else {
                throw PlaybackEngineError.unsupported
            }

            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            try await waitUntilReadyToPlay(item, generation: generation)
            installItemObservers(for: item)

            let seconds = assetDuration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : 0
        } catch let error as PlaybackEngineError {
            throw error
        } catch is CancellationError {
            throw PlaybackEngineError.superseded
        } catch {
            throw PlaybackEngineError.cannotOpen
        }
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        guard let surface = surface as? any AVPlayerRenderSurface else {
            throw PlaybackEngineError.incompatibleSurface
        }

        surfaceGeneration &+= 1
        let generation = surfaceGeneration
        let previousSurface = attachedSurface

        if let previousSurface,
           ObjectIdentifier(previousSurface) == ObjectIdentifier(surface) {
            previousSurface.connect(to: player)
            guard player.currentItem != nil else {
                return
            }
            do {
                if player.timeControlStatus == .paused {
                    prerollCurrentItem()
                }
                try await waitUntilReady(surface, generation: generation)
                guard generation == surfaceGeneration else {
                    throw PlaybackEngineError.superseded
                }
            } catch {
                player.cancelPendingPrerolls()
                throw error
            }
            return
        }

        previousSurface?.connect(to: nil)
        attachedSurface = nil
        surface.connect(to: player)

        guard player.currentItem != nil else {
            attachedSurface = surface
            return
        }

        do {
            if player.timeControlStatus == .paused {
                prerollCurrentItem()
            }
            try await waitUntilReady(surface, generation: generation)
            guard generation == surfaceGeneration else {
                throw PlaybackEngineError.superseded
            }
            attachedSurface = surface
        } catch {
            surface.connect(to: nil)
            player.cancelPendingPrerolls()
            if generation == surfaceGeneration {
                previousSurface?.connect(to: player)
                attachedSurface = previousSurface
            }
            throw error
        }
    }

    func detachAll() {
        surfaceGeneration &+= 1
        attachedSurface?.connect(to: nil)
        attachedSurface = nil
    }

    func play(at rate: PlaybackRate) {
        guard player.currentItem != nil else {
            return
        }
        player.playImmediately(atRate: rate.rawValue)
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: TimeInterval) {
        seek(to: seconds, mode: .exact)
    }

    func seek(to seconds: TimeInterval, mode: PlaybackSeekMode) {
        seekCoalescer.seek(to: seconds, mode: mode)
    }

    func setProgressCadence(_ cadence: PlaybackProgressCadence) {
        guard cadence != progressCadence else {
            return
        }

        progressCadence = cadence
        refreshProgressObserver()
        publishCurrentProgressIfAvailable()
    }

    private func performSeek(
        to seconds: TimeInterval,
        mode: PlaybackSeekMode,
        completion: @escaping PlaybackSeekCoalescer.Completion
    ) {
        let target = CMTime(
            seconds: max(seconds, 0),
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        let tolerance: CMTime
        switch mode {
        case .interactive:
            tolerance = CMTime(
                seconds: PlaybackPolicy.interactiveSeekTolerance,
                preferredTimescale: CMTimeScale(NSEC_PER_SEC)
            )
        case .exact:
            player.currentItem?.cancelPendingSeeks()
            tolerance = .zero
        }
        player.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { _ in
            completion()
        }
    }

    func setVolume(_ volume: PlaybackVolume) {
        player.volume = volume.rawValue
    }

    func setMuted(_ isMuted: Bool) {
        player.isMuted = isMuted
    }

    func stop() {
        loadGeneration &+= 1
        surfaceGeneration &+= 1
        seekCoalescer.invalidate()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        removeProgressObserver()
        removeTimeControlObservation()
        detachAll()
    }

    private func installProgressObserver() {
        guard timeObserver == nil,
              progressHandler != nil,
              let progressUpdateInterval else {
            return
        }
        let interval = CMTime(
            seconds: progressUpdateInterval,
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else {
                return
            }
            MainActor.assumeIsolated {
                self?.progressHandler?(seconds)
            }
        }
    }

    private func removeProgressObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func refreshProgressObserver() {
        removeProgressObserver()
        installProgressObserver()
    }

    private func publishCurrentProgressIfAvailable() {
        guard progressCadence != .inactive,
              progressHandler != nil,
              player.currentItem != nil else {
            return
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else {
            return
        }
        progressHandler?(seconds)
    }

    private var progressUpdateInterval: TimeInterval? {
        switch progressCadence {
        case .inactive:
            return nil
        case .background:
            return PlaybackPolicy.backgroundProgressUpdateInterval
        case .visible:
            return PlaybackPolicy.visibleProgressUpdateInterval
        }
    }

    private func installTimeControlObservation() {
        guard timeControlObservation == nil else {
            return
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                self?.playbackActivityHandler?(isPlaying)
            }
        }
    }

    private func removeTimeControlObservation() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
    }

    private func installItemObservers(for item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.itemEndedHandler?()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failureHandler?(.cannotOpen)
            }
        }
    }

    private func removeItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

    private func prerollCurrentItem() {
        player.preroll(atRate: PlaybackPolicy.defaultRate.rawValue) { _ in }
    }

    private func waitUntilReady(
        _ surface: any PlaybackRenderSurface,
        generation: UInt64
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0

        while !surface.isReadyForDisplay {
            try Task.checkCancellation()
            guard generation == surfaceGeneration else {
                throw PlaybackEngineError.superseded
            }
            guard elapsedNanoseconds < PlaybackPolicy.surfaceReadyTimeoutNanoseconds else {
                throw PlaybackEngineError.surfaceTimeout
            }

            try await Task.sleep(nanoseconds: PlaybackPolicy.surfacePollIntervalNanoseconds)
            elapsedNanoseconds += PlaybackPolicy.surfacePollIntervalNanoseconds
        }
    }

    private func waitUntilReadyToPlay(
        _ item: AVPlayerItem,
        generation: UInt64
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0

        while item.status == .unknown {
            try Task.checkCancellation()
            guard generation == loadGeneration else {
                throw PlaybackEngineError.superseded
            }
            guard elapsedNanoseconds < PlaybackPolicy.itemReadyTimeoutNanoseconds else {
                throw PlaybackEngineError.cannotOpen
            }

            try await Task.sleep(nanoseconds: PlaybackPolicy.surfacePollIntervalNanoseconds)
            elapsedNanoseconds += PlaybackPolicy.surfacePollIntervalNanoseconds
        }

        guard item.status == .readyToPlay else {
            throw PlaybackEngineError.cannotOpen
        }
    }
}
