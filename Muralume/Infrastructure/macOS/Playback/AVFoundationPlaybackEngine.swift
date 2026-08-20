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

    private let player: AVPlayer
    private weak var attachedSurface: (any AVPlayerRenderSurface)?
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var mediaSelectionContext: AVFoundationMediaSelectionContext?
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

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
    }

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
        mediaSelectionContext = nil

        let asset = AVURLAsset(url: source.url)

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
            mediaSelectionContext = AVFoundationMediaSelectionContext(
                item: item,
                audioGroup: loadedAudioGroup,
                subtitleGroup: loadedSubtitleGroup,
                generation: generation
            )

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
            previousSurface.connect(to: player)
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
        player.cancelPendingPrerolls()
        attachedSurface?.connect(to: nil)
        attachedSurface = nil
        configureDisplaySleepPrevention(for: nil)
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
        return context.state
    }

    func stop() {
        loadGeneration &+= 1
        surfaceGeneration &+= 1
        seekCoalescer.invalidate()
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaSelectionContext = nil
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

@MainActor
private struct AVFoundationMediaSelectionContext {
    let item: AVPlayerItem
    let audioGroup: AVMediaSelectionGroup?
    let subtitleGroup: AVMediaSelectionGroup?
    let audioOptions: [PlaybackMediaOption]
    let subtitleOptions: [PlaybackMediaOption]

    private let audioOptionsByID: [
        PlaybackMediaOptionID: AVMediaSelectionOption
    ]
    private let subtitleOptionsByID: [
        PlaybackMediaOptionID: AVMediaSelectionOption
    ]
    private(set) var audioSelection: PlaybackAudioSelection = .automatic
    private(set) var subtitleSelection: PlaybackSubtitleSelection = .automatic

    init(
        item: AVPlayerItem,
        audioGroup: AVMediaSelectionGroup?,
        subtitleGroup: AVMediaSelectionGroup?,
        generation: UInt64
    ) {
        self.item = item
        self.audioGroup = audioGroup
        self.subtitleGroup = subtitleGroup

        let audioMappings = Self.makeOptions(
            group: audioGroup,
            prefix: "audio-\(generation)"
        )
        audioOptions = audioMappings.options
        audioOptionsByID = audioMappings.optionsByID

        let subtitleMappings = Self.makeOptions(
            group: subtitleGroup,
            prefix: "subtitle-\(generation)"
        )
        subtitleOptions = subtitleMappings.options
        subtitleOptionsByID = subtitleMappings.optionsByID
    }

    var state: PlaybackMediaSelectionState {
        PlaybackMediaSelectionState(
            audioOptions: audioOptions,
            subtitleOptions: subtitleOptions,
            audioSelection: audioSelection,
            subtitleSelection: subtitleSelection,
            effectiveAudioOptionID: selectedOptionID(
                group: audioGroup,
                optionsByID: audioOptionsByID
            ),
            effectiveSubtitleOptionID: selectedOptionID(
                group: subtitleGroup,
                optionsByID: subtitleOptionsByID
            ),
            allowsEmptySubtitleSelection:
                subtitleGroup?.allowsEmptySelection ?? true
        )
    }

    mutating func selectAudio(_ selection: PlaybackAudioSelection) {
        guard let audioGroup else {
            return
        }
        switch selection {
        case .automatic:
            item.selectMediaOptionAutomatically(in: audioGroup)
        case let .option(id):
            guard let option = audioOptionsByID[id] else {
                return
            }
            item.select(option, in: audioGroup)
        }
        audioSelection = selection
    }

    mutating func selectSubtitles(
        _ selection: PlaybackSubtitleSelection
    ) {
        guard let subtitleGroup else {
            return
        }
        switch selection {
        case .automatic:
            item.selectMediaOptionAutomatically(in: subtitleGroup)
        case .off:
            guard subtitleGroup.allowsEmptySelection else {
                return
            }
            item.select(nil, in: subtitleGroup)
        case let .option(id):
            guard let option = subtitleOptionsByID[id] else {
                return
            }
            item.select(option, in: subtitleGroup)
        }
        subtitleSelection = selection
    }

    private func selectedOptionID(
        group: AVMediaSelectionGroup?,
        optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption]
    ) -> PlaybackMediaOptionID? {
        guard let group,
              let selectedOption = item.currentMediaSelection
                .selectedMediaOption(in: group) else {
            return nil
        }
        return optionsByID.first { _, option in
            option === selectedOption
        }?.key
    }

    private static func makeOptions(
        group: AVMediaSelectionGroup?,
        prefix: String
    ) -> (
        options: [PlaybackMediaOption],
        optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption]
    ) {
        guard let group else {
            return ([], [:])
        }

        var options: [PlaybackMediaOption] = []
        var optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption] = [:]
        options.reserveCapacity(group.options.count)
        optionsByID.reserveCapacity(group.options.count)

        for (index, option) in group.options.enumerated() {
            let id = PlaybackMediaOptionID(
                rawValue: "\(prefix)-\(index)"
            )
            options.append(
                PlaybackMediaOption(
                    id: id,
                    displayName: option.displayName,
                    languageIdentifier: option.extendedLanguageTag
                        ?? option.locale?.identifier,
                    characteristics: characteristics(of: option)
                )
            )
            optionsByID[id] = option
        }
        return (options, optionsByID)
    }

    private static func characteristics(
        of option: AVMediaSelectionOption
    ) -> Set<PlaybackMediaOptionCharacteristic> {
        var characteristics: Set<PlaybackMediaOptionCharacteristic> = []
        if option.hasMediaCharacteristic(.describesVideoForAccessibility) {
            characteristics.insert(.audioDescription)
        }
        if option.hasMediaCharacteristic(.dubbedTranslation)
            || option.hasMediaCharacteristic(.voiceOverTranslation) {
            characteristics.insert(.dubbedTranslation)
        }
        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            characteristics.insert(.forcedSubtitles)
        }
        if option.hasMediaCharacteristic(
            .transcribesSpokenDialogForAccessibility
        ) || option.hasMediaCharacteristic(
            .describesMusicAndSoundForAccessibility
        ) {
            characteristics.insert(.closedCaptions)
        }
        return characteristics
    }
}
