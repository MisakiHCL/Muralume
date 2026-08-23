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
    private var externalSubtitleTimeHandler: ((TimeInterval) -> Void)?
    private var embeddedSubtitleCueHandler: ((String?) -> Void)?

    private var player: AVPlayer
    private weak var attachedSurface: (any AVPlayerRenderSurface)?
    private var timeObserver: Any?
    private var subtitleTimeObserver: Any?
    private var selectedEmbeddedSubtitleTimeline: SubtitleTimeline?
    private var publishedEmbeddedSubtitleCueText: String?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var playerLooper: AVPlayerLooper?
    private var looperStatusObservation: NSKeyValueObservation?
    private var mediaSelectionContext: AVFoundationMediaSelectionContext?
    private var compatibilityLease: MediaPlaybackURLLease?
    private var retiringCompatibilityLease: MediaPlaybackURLLease?
    private var retiringPlayer: AVPlayer?
    private var transitionTask: Task<Void, Never>?
    private var isSurfaceTransitionActive = false
    private var isLooping = false
    private var requestedRate: PlaybackRate?
    private var configuredVolume: PlaybackVolume
    private var configuredMuted: Bool
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

    init(player: AVPlayer = AVQueuePlayer()) {
        self.player = player
        configuredVolume = PlaybackVolume(rawValue: player.volume)
        configuredMuted = player.isMuted
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        try await load(source, transition: .immediate)
    }

    func load(
        _ source: ResolvedMediaSource,
        transition: PlaybackItemTransition
    ) async throws -> TimeInterval {
        cancelActiveTransition(reconnectActivePlayer: true)
        seekCoalescer.invalidate()
        let outgoingPlayer = player
        let transitionSurface = attachedSurface
            as? any AVPlayerTransitionSurface
        let transitionDuration = crossfadeDuration(
            for: transition,
            surface: transitionSurface,
            outgoingPlayer: outgoingPlayer
        )
        let usesCrossfade = transitionDuration != nil
        if !usesCrossfade {
            outgoingPlayer.pause()
        }
        outgoingPlayer.currentItem?.cancelPendingSeeks()
        loadGeneration &+= 1
        let generation = loadGeneration
        removeItemObservers()
        removeProgressObserver()
        removeSubtitleTimeObserver()
        removeTimeControlObservation()
        mediaSelectionContext = nil
        legibleOutput = nil
        selectedEmbeddedSubtitleTimeline = nil
        publishEmbeddedSubtitleCueText(nil)

        let sourceLease: MediaPlaybackURLLease
        do {
            sourceLease = try MediaPlaybackURLLease(sourceURL: source.url)
        } catch {
            throw PlaybackEngineError.cannotOpen
        }
        let asset = AVURLAsset(url: sourceLease.url)
        let embeddedSubtitleTask = Task.detached(priority: .utility) {
            try await EmbeddedSubtitleParser().parse(sourceLease.url)
        }

        do {
            async let playable = asset.load(.isPlayable)
            async let duration = asset.load(.duration)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioGroup = asset.loadMediaSelectionGroup(
                for: .audible
            )
            async let subtitleGroup = asset.loadMediaSelectionGroup(
                for: .legible
            )
            let (
                isPlayable,
                assetDuration,
                tracks,
                loadedAudioGroup,
                loadedSubtitleGroup
            ) = try await (
                playable,
                duration,
                videoTracks,
                audioGroup,
                subtitleGroup
            )
            let embeddedSubtitleTracks: [EmbeddedSubtitleTrackData]
            if let loadedSubtitleGroup,
               !loadedSubtitleGroup.options.isEmpty {
                embeddedSubtitleTracks = await withTaskCancellationHandler {
                    (try? await embeddedSubtitleTask.value) ?? []
                } onCancel: {
                    embeddedSubtitleTask.cancel()
                }
            } else {
                embeddedSubtitleTask.cancel()
                embeddedSubtitleTracks = []
            }

            try Task.checkCancellation()
            guard generation == loadGeneration else {
                throw PlaybackEngineError.superseded
            }
            guard isPlayable, !tracks.isEmpty else {
                throw PlaybackEngineError.unsupported
            }

            let item = AVPlayerItem(asset: asset)
            let selectionContext = AVFoundationMediaSelectionContext(
                item: item,
                audioGroup: loadedAudioGroup,
                subtitleGroup: loadedSubtitleGroup,
                embeddedSubtitleTracks: embeddedSubtitleTracks,
                generation: generation
            )
            if selectionContext.canRenderEmbeddedSubtitles, !isLooping {
                let output = AVPlayerItemLegibleOutput()
                output.suppressesPlayerRendering = true
                item.add(output)
                legibleOutput = output
            }
            let incomingPlayer = usesCrossfade
                ? makeConfiguredPlayer()
                : outgoingPlayer
            let playbackItem = try install(
                item,
                on: incomingPlayer,
                generation: generation
            )
            try await waitUntilReadyToPlay(
                playbackItem,
                generation: generation
            )
            if let transitionSurface, let transitionDuration {
                try await prepareCrossfade(
                    surface: transitionSurface,
                    outgoingPlayer: outgoingPlayer,
                    incomingPlayer: incomingPlayer,
                    sourceLease: sourceLease,
                    duration: transitionDuration,
                    generation: generation
                )
            } else {
                compatibilityLease?.invalidate()
                compatibilityLease = sourceLease
            }
            installItemObservers(for: playbackItem)
            mediaSelectionContext = selectionContext
            refreshSelectedEmbeddedSubtitleTimeline()
            refreshProgressObserver()
            refreshSubtitleTimeObserver()
            if playbackActivityHandler != nil {
                installTimeControlObservation()
            }

            let seconds = assetDuration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : 0
        } catch let error as PlaybackEngineError {
            embeddedSubtitleTask.cancel()
            throw error
        } catch is CancellationError {
            embeddedSubtitleTask.cancel()
            throw PlaybackEngineError.superseded
        } catch {
            embeddedSubtitleTask.cancel()
            throw PlaybackEngineError.cannotOpen
        }
    }

    private func install(
        _ item: AVPlayerItem,
        on targetPlayer: AVPlayer,
        generation: UInt64
    ) throws -> AVPlayerItem {
        disablePlayerLooper()
        targetPlayer.pause()
        targetPlayer.appliesMediaSelectionCriteriaAutomatically = false
        targetPlayer.volume = configuredVolume.rawValue
        targetPlayer.isMuted = configuredMuted

        if isLooping {
            guard let queuePlayer = targetPlayer as? AVQueuePlayer else {
                throw PlaybackEngineError.cannotOpen
            }
            queuePlayer.removeAllItems()
            let looper = AVPlayerLooper(
                player: queuePlayer,
                templateItem: item
            )
            playerLooper = looper
            looperStatusObservation = looper.observe(
                \.status,
                options: [.initial, .new]
            ) { [weak self] looper, _ in
                guard looper.status == .failed else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == loadGeneration else {
                        return
                    }
                    failureHandler?(.cannotOpen)
                }
            }
            guard let playbackItem = queuePlayer.currentItem else {
                throw PlaybackEngineError.cannotOpen
            }
            return playbackItem
        }

        if let queuePlayer = targetPlayer as? AVQueuePlayer {
            queuePlayer.removeAllItems()
            queuePlayer.insert(item, after: nil)
        } else {
            targetPlayer.replaceCurrentItem(with: item)
        }
        return item
    }

    private func makeConfiguredPlayer() -> AVPlayer {
        let incomingPlayer = AVPlayer()
        incomingPlayer.appliesMediaSelectionCriteriaAutomatically = false
        incomingPlayer.volume = configuredVolume.rawValue
        incomingPlayer.isMuted = configuredMuted
        incomingPlayer.preventsDisplaySleepDuringVideoPlayback =
            attachedSurface?.id == .player
        return incomingPlayer
    }

    private func crossfadeDuration(
        for transition: PlaybackItemTransition,
        surface: (any AVPlayerTransitionSurface)?,
        outgoingPlayer: AVPlayer
    ) -> TimeInterval? {
        guard !isLooping,
              surface != nil,
              outgoingPlayer.currentItem != nil,
              case let .crossfade(duration) = transition,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        return duration
    }

    private func prepareCrossfade(
        surface: any AVPlayerTransitionSurface,
        outgoingPlayer: AVPlayer,
        incomingPlayer: AVPlayer,
        sourceLease: MediaPlaybackURLLease,
        duration: TimeInterval,
        generation: UInt64
    ) async throws {
        surface.prepareTransition(to: incomingPlayer)
        incomingPlayer.preroll(atRate: requestedRate?.rawValue
            ?? PlaybackPolicy.defaultRate.rawValue) { _ in }
        do {
            try await waitUntilReady(
                surface,
                generation: surfaceGeneration
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else {
                throw PlaybackEngineError.superseded
            }
        } catch {
            surface.cancelPreparedTransition()
            incomingPlayer.cancelPendingPrerolls()
            incomingPlayer.replaceCurrentItem(with: nil)
            throw error
        }

        let outgoingLease = compatibilityLease
        player = incomingPlayer
        compatibilityLease = sourceLease
        incomingPlayer.volume = 0
        if let requestedRate {
            incomingPlayer.playImmediately(atRate: requestedRate.rawValue)
        }
        surface.commitPreparedTransition(duration: duration)
        beginCrossfadeCleanup(
            outgoingPlayer: outgoingPlayer,
            outgoingLease: outgoingLease,
            incomingPlayer: incomingPlayer,
            duration: duration,
            generation: generation
        )
    }

    private func beginCrossfadeCleanup(
        outgoingPlayer: AVPlayer,
        outgoingLease: MediaPlaybackURLLease?,
        incomingPlayer: AVPlayer,
        duration: TimeInterval,
        generation: UInt64
    ) {
        retiringPlayer = outgoingPlayer
        retiringCompatibilityLease = outgoingLease
        isSurfaceTransitionActive = true
        transitionTask?.cancel()
        let stepCount = max(PlaybackPolicy.queueCrossfadeAudioStepCount, 1)
        let stepNanoseconds = UInt64(
            duration * Double(NSEC_PER_SEC) / Double(stepCount)
        )
        transitionTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for step in 1...stepCount {
                do {
                    try await Task.sleep(nanoseconds: stepNanoseconds)
                } catch {
                    return
                }
                guard generation == loadGeneration,
                      player === incomingPlayer else {
                    return
                }
                let progress = Float(step) / Float(stepCount)
                outgoingPlayer.volume = configuredVolume.rawValue
                    * (1 - progress)
                incomingPlayer.volume = configuredVolume.rawValue * progress
            }
            finishActiveTransition()
        }
    }

    private func finishActiveTransition() {
        transitionTask = nil
        retiringPlayer?.pause()
        retiringPlayer?.replaceCurrentItem(with: nil)
        retiringPlayer = nil
        retiringCompatibilityLease?.invalidate()
        retiringCompatibilityLease = nil
        player.volume = configuredVolume.rawValue
        player.isMuted = configuredMuted
        isSurfaceTransitionActive = false
    }

    private func cancelActiveTransition(reconnectActivePlayer: Bool) {
        transitionTask?.cancel()
        transitionTask = nil
        (attachedSurface as? any AVPlayerTransitionSurface)?
            .cancelPreparedTransition()
        retiringPlayer?.pause()
        retiringPlayer?.replaceCurrentItem(with: nil)
        retiringPlayer = nil
        retiringCompatibilityLease?.invalidate()
        retiringCompatibilityLease = nil
        player.volume = configuredVolume.rawValue
        player.isMuted = configuredMuted
        isSurfaceTransitionActive = false
        if reconnectActivePlayer {
            attachedSurface?.connect(to: player)
        }
    }

    private func disablePlayerLooper() {
        looperStatusObservation?.invalidate()
        looperStatusObservation = nil
        playerLooper?.disableLooping()
        playerLooper = nil
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        try await attach(to: surface, readinessPolicy: .required)
    }

    func attach(
        to surface: any PlaybackRenderSurface,
        readinessPolicy: PlaybackSurfaceReadinessPolicy
    ) async throws {
        guard let surface = surface as? any AVPlayerRenderSurface else {
            throw PlaybackEngineError.incompatibleSurface
        }

        configureDisplaySleepPrevention(for: surface)

        surfaceGeneration &+= 1
        let generation = surfaceGeneration
        let previousSurface = attachedSurface

        if let previousSurface,
           ObjectIdentifier(previousSurface) == ObjectIdentifier(surface) {
            if !isSurfaceTransitionActive {
                previousSurface.connect(to: player)
            }
            guard player.currentItem != nil else {
                return
            }
            if player.timeControlStatus == .paused {
                prerollCurrentItem()
            }
            guard readinessPolicy == .required else {
                return
            }
            do {
                try await waitUntilReady(surface, generation: generation)
                guard generation == surfaceGeneration else {
                    throw PlaybackEngineError.superseded
                }
            } catch {
                guard generation == surfaceGeneration else {
                    throw PlaybackEngineError.superseded
                }
                player.cancelPendingPrerolls()
                throw error
            }
            return
        }

        previousSurface?.connect(to: nil)
        surface.connect(to: player)
        // Treat the connected surface as current while readiness is pending.
        // A newer attachment must be able to supersede and disconnect it even
        // before the first rendered frame arrives.
        attachedSurface = surface

        guard player.currentItem != nil else {
            return
        }

        if player.timeControlStatus == .paused {
            prerollCurrentItem()
        }
        guard readinessPolicy == .required else {
            return
        }

        do {
            try await waitUntilReady(surface, generation: generation)
            guard generation == surfaceGeneration else {
                throw PlaybackEngineError.superseded
            }
        } catch {
            // A stale task no longer owns either the render connection or the
            // player's shared preroll state. In particular, it must not tear
            // down a newer attachment to the same surface instance.
            guard generation == surfaceGeneration else {
                throw PlaybackEngineError.superseded
            }
            surface.connect(to: nil)
            player.cancelPendingPrerolls()
            previousSurface?.connect(to: player)
            attachedSurface = previousSurface
            configureDisplaySleepPrevention(for: previousSurface)
            throw error
        }
    }

    func detachAll() {
        surfaceGeneration &+= 1
        cancelActiveTransition(reconnectActivePlayer: false)
        player.cancelPendingPrerolls()
        attachedSurface?.connect(to: nil)
        attachedSurface = nil
        configureDisplaySleepPrevention(for: nil)
    }

    func play(at rate: PlaybackRate) {
        guard player.currentItem != nil else {
            return
        }
        requestedRate = rate
        player.playImmediately(atRate: rate.rawValue)
    }

    func pause() {
        requestedRate = nil
        player.pause()
        retiringPlayer?.pause()
    }

    private func configureDisplaySleepPrevention(
        for surface: (any AVPlayerRenderSurface)?
    ) {
        player.preventsDisplaySleepDuringVideoPlayback = surface?.id == .player
    }

    func seek(to seconds: TimeInterval) {
        seek(to: seconds, mode: .exact)
    }

    func seek(to seconds: TimeInterval, mode: PlaybackSeekMode) {
        seekCoalescer.seek(to: seconds, mode: mode)
    }

    func seekBeforePlayback(to seconds: TimeInterval) async {
        seekCoalescer.invalidate()
        player.currentItem?.cancelPendingSeeks()
        let target = CMTime(
            seconds: max(seconds, 0),
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        await withCheckedContinuation { continuation in
            player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
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
        configuredVolume = volume
        player.volume = volume.rawValue
        if isSurfaceTransitionActive {
            retiringPlayer?.volume = volume.rawValue
        }
    }

    func setMuted(_ isMuted: Bool) {
        configuredMuted = isMuted
        player.isMuted = isMuted
        retiringPlayer?.isMuted = isMuted
    }

    func setLooping(_ isLooping: Bool) {
        self.isLooping = isLooping
    }

    func currentMediaSelectionState() -> PlaybackMediaSelectionState {
        mediaSelectionContext?.state ?? .empty
    }

    func selectAudio(
        _ selection: PlaybackAudioSelection
    ) -> PlaybackMediaSelectionState {
        guard var context = mediaSelectionContext,
              context.item === player.currentItem else {
            return .empty
        }
        context.selectAudio(selection)
        mediaSelectionContext = context
        return context.state
    }

    func selectSubtitles(
        _ selection: PlaybackSubtitleSelection
    ) -> PlaybackMediaSelectionState {
        guard var context = mediaSelectionContext,
              context.item === player.currentItem else {
            return .empty
        }
        context.selectSubtitles(selection)
        mediaSelectionContext = context
        refreshSelectedEmbeddedSubtitleTimeline()
        return context.state
    }

    func setExternalSubtitleTimeHandler(
        _ handler: ((TimeInterval) -> Void)?
    ) {
        externalSubtitleTimeHandler = handler
        refreshSubtitleTimeObserver()
        publishCurrentExternalSubtitleTimeIfAvailable()
    }

    func setEmbeddedSubtitleCueHandler(
        _ handler: ((String?) -> Void)?
    ) {
        embeddedSubtitleCueHandler = handler
        refreshSubtitleTimeObserver()
        publishCurrentEmbeddedSubtitleCueIfAvailable()
    }

    func stop() {
        loadGeneration &+= 1
        surfaceGeneration &+= 1
        requestedRate = nil
        cancelActiveTransition(reconnectActivePlayer: false)
        disablePlayerLooper()
        seekCoalescer.invalidate()
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        player.pause()
        if let queuePlayer = player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            player.replaceCurrentItem(with: nil)
        }
        compatibilityLease?.invalidate()
        compatibilityLease = nil
        mediaSelectionContext = nil
        legibleOutput = nil
        externalSubtitleTimeHandler = nil
        updateSelectedEmbeddedSubtitleTimeline(nil)
        removeItemObservers()
        removeProgressObserver()
        removeSubtitleTimeObserver()
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

    private func installSubtitleTimeObserver() {
        guard subtitleTimeObserver == nil,
              externalSubtitleTimeHandler != nil
                || (
                    embeddedSubtitleCueHandler != nil
                        && selectedEmbeddedSubtitleTimeline != nil
                ),
              player.currentItem != nil else {
            return
        }
        let interval = CMTime(
            seconds: ExternalSubtitlePolicy.timeUpdateInterval,
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )
        subtitleTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else {
                return
            }
            MainActor.assumeIsolated {
                self?.externalSubtitleTimeHandler?(seconds)
                self?.publishEmbeddedSubtitleCue(at: seconds)
            }
        }
    }

    private func removeSubtitleTimeObserver() {
        if let subtitleTimeObserver {
            player.removeTimeObserver(subtitleTimeObserver)
            self.subtitleTimeObserver = nil
        }
    }

    private func refreshSubtitleTimeObserver() {
        removeSubtitleTimeObserver()
        installSubtitleTimeObserver()
    }

    private func publishCurrentExternalSubtitleTimeIfAvailable() {
        guard externalSubtitleTimeHandler != nil,
              player.currentItem != nil else {
            return
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else {
            return
        }
        externalSubtitleTimeHandler?(seconds)
    }

    private func publishCurrentEmbeddedSubtitleCueIfAvailable() {
        guard embeddedSubtitleCueHandler != nil else {
            return
        }
        guard selectedEmbeddedSubtitleTimeline != nil,
              player.currentItem != nil else {
            publishEmbeddedSubtitleCueText(nil)
            return
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else {
            return
        }
        publishEmbeddedSubtitleCue(at: seconds)
    }

    private func publishEmbeddedSubtitleCue(at seconds: TimeInterval) {
        publishEmbeddedSubtitleCueText(
            selectedEmbeddedSubtitleTimeline?.text(at: seconds)
        )
    }

    private func publishEmbeddedSubtitleCueText(_ cueText: String?) {
        guard cueText != publishedEmbeddedSubtitleCueText else {
            return
        }
        publishedEmbeddedSubtitleCueText = cueText
        embeddedSubtitleCueHandler?(cueText)
    }

    private func refreshSelectedEmbeddedSubtitleTimeline() {
        updateSelectedEmbeddedSubtitleTimeline(
            mediaSelectionContext?.selectedEmbeddedSubtitleTimeline
        )
    }

    private func updateSelectedEmbeddedSubtitleTimeline(
        _ timeline: SubtitleTimeline?
    ) {
        selectedEmbeddedSubtitleTimeline = timeline
        publishEmbeddedSubtitleCueText(nil)
        refreshSubtitleTimeObserver()
        publishCurrentEmbeddedSubtitleCueIfAvailable()
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
