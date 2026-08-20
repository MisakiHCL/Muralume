import Combine
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    var playbackFailureHandler: ((PlaybackFailure) -> Void)?
    var itemEndedHandler: (() -> PlaybackItemEndDisposition)?
    var itemFailureHandler: ((PlaybackFailure) -> Bool)?

    @Published private(set) var source: ResolvedMediaSource?
    @Published private(set) var readiness: PlaybackReadiness = .empty {
        didSet {
            updateProgressCadence()
        }
    }
    @Published private(set) var presentation: PlaybackPresentation = .player {
        didSet {
            updatePublishedSuspensionState()
            updateProgressCadence()
        }
    }
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isActuallyPlaying = false
    @Published private(set) var isPlaybackRequested = false
    @Published private(set) var hasPlayableMedia = false
    @Published private(set) var settings: PlaybackSettings
    @Published private(set) var temporaryPlaybackRate: PlaybackRate?
    @Published private(set) var isPlayerWindowDismissed = false {
        didSet {
            updateProgressCadence()
        }
    }
    @Published private(set) var isSystemSuspended = false {
        didSet {
            updateProgressCadence()
        }
    }
    @Published private(set) var isDesktopEngineDetached = false {
        didSet {
            updateProgressCadence()
        }
    }

    let mediaSelection: PlaybackMediaSelectionController
    let subtitleAppearance: SubtitleAppearanceController

    var canPresentOnDesktop: Bool {
        readiness == .ready
            && presentation == .player
    }

    private let engine: any PlaybackEngine
    private let preferencesStore: (any AppPreferencesStoring)?
    private let audioPreferencesPersistenceDelay: Duration
    private var gate = PlaybackGate()
    private weak var playerSurface: (any PlaybackRenderSurface)?
    private var playerSurfaceAttachmentTask: Task<Void, Never>?
    private var playerSurfaceAttachmentGeneration: UInt64 = 0
    private weak var attachingPlayerSurface: (any PlaybackRenderSurface)?
    private weak var attachedPlayerSurface: (any PlaybackRenderSurface)?
    private var audioPreferencesSaveTask: Task<Void, Never>?
    private var pendingAudioPreferences: PlaybackAudioPreferences?
    private var savedPlayerSettings: PlaybackSettings?
    private var playbackRateOverrideToken: PlaybackRateOverrideToken?
    private var transitionGeneration: UInt64 = 0
    private var mediaLoadGeneration: UInt64 = 0
    private var timelineSeekTarget: TimeInterval?
    private var hasHandledCurrentItemEnd = false
    private var appliedProgressCadence: PlaybackProgressCadence?

    init(
        engine: any PlaybackEngine,
        initialPreferences: AppPreferences = .defaultValue,
        preferencesStore: (any AppPreferencesStoring)? = nil,
        externalSubtitleParser: (any SubtitleFileParsing)? = nil,
        externalSubtitleDiscovery:
            (any ExternalSubtitleDiscovering)? = nil,
        externalSubtitleAssociationStore:
            (any ExternalSubtitleAssociationStoring)? = nil,
        audioPreferencesPersistenceDelay: Duration =
            PlaybackPolicy.audioPreferencesPersistenceDelay
    ) {
        self.engine = engine
        mediaSelection = PlaybackMediaSelectionController(
            engine: engine,
            externalSubtitleParser: externalSubtitleParser,
            externalSubtitleDiscovery: externalSubtitleDiscovery,
            externalSubtitleAssociationStore:
                externalSubtitleAssociationStore
        )
        subtitleAppearance = SubtitleAppearanceController(
            preferences: initialPreferences.subtitleAppearance,
            store: preferencesStore
        )
        self.preferencesStore = preferencesStore
        self.audioPreferencesPersistenceDelay =
            audioPreferencesPersistenceDelay
        settings = PlaybackSettings(
            volume: initialPreferences.audio.volume,
            isMuted: initialPreferences.audio.isMuted,
            rate: initialPreferences.playbackRate,
            restorableVolume: initialPreferences.audio.restorableVolume
        )
        engine.progressHandler = { [weak self] seconds in
            self?.handleProgress(seconds)
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
        updateProgressCadence()
        applySettings(settings)
    }

    deinit {
        playerSurfaceAttachmentTask?.cancel()
        audioPreferencesSaveTask?.cancel()
    }

    func registerPlayerSurface(_ surface: any PlaybackRenderSurface) {
        playerSurface = surface
        guard presentation == .player,
              readiness == .ready,
              !isPlayerWindowDismissed else {
            return
        }
        if isSameSurface(attachedPlayerSurface, surface) {
            applyPlaybackGate()
            return
        }
        if playerSurfaceAttachmentTask != nil,
           isSameSurface(attachingPlayerSurface, surface) {
            return
        }

        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        let expectedGeneration = transitionGeneration
        let attachmentGeneration = playerSurfaceAttachmentGeneration
        attachingPlayerSurface = surface

        playerSurfaceAttachmentTask = Task { [weak self] in
            guard let self,
                  presentation == .player,
                  readiness == .ready,
                  !isPlayerWindowDismissed,
                  isCurrentPlayerSurface(surface),
                  transitionGeneration == expectedGeneration,
                  playerSurfaceAttachmentGeneration
                    == attachmentGeneration else {
                return
            }
            do {
                try await engine.attach(to: surface)
                try Task.checkCancellation()
                guard presentation == .player,
                      readiness == .ready,
                      !isPlayerWindowDismissed,
                      isCurrentPlayerSurface(surface),
                      transitionGeneration == expectedGeneration,
                      playerSurfaceAttachmentGeneration
                        == attachmentGeneration else {
                    return
                }
                attachedPlayerSurface = surface
                finishPlayerSurfaceAttachment(
                    generation: attachmentGeneration
                )
                applyPlaybackGate()
            } catch is CancellationError {
                finishPlayerSurfaceAttachment(
                    generation: attachmentGeneration
                )
                return
            } catch let error as PlaybackEngineError
                where error == .superseded {
                finishPlayerSurfaceAttachment(
                    generation: attachmentGeneration
                )
                return
            } catch {
                guard presentation == .player,
                      transitionGeneration == expectedGeneration,
                      readiness == .ready,
                      !isPlayerWindowDismissed,
                      isCurrentPlayerSurface(surface),
                      playerSurfaceAttachmentGeneration
                        == attachmentGeneration else {
                    return
                }
                finishPlayerSurfaceAttachment(
                    generation: attachmentGeneration
                )
                handleRecoverablePlayerSurfaceFailure()
            }
        }
    }

    @discardableResult
    func load(
        _ source: ResolvedMediaSource,
        autoplay: Bool = true,
        attachToPlayerSurface: Bool = true
    ) async -> PlaybackLoadResult {
        guard presentation != .terminating else {
            return .cancelled
        }

        cancelTimelineSeek()
        clearTemporaryPlaybackRateOverride()
        mediaSelection.reset()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        mediaLoadGeneration &+= 1
        let loadGeneration = mediaLoadGeneration
        let presentationGeneration = transitionGeneration
        let canAutoplayWhenLoaded = !isPlayerWindowDismissed
        self.source = source
        readiness = .loading
        currentTime = 0
        duration = 0

        let loadedDuration: TimeInterval
        do {
            loadedDuration = try await engine.load(source)
            try Task.checkCancellation()
        } catch let error as PlaybackEngineError {
            guard loadGeneration == mediaLoadGeneration else {
                return .cancelled
            }
            return handleLoadFailure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard loadGeneration == mediaLoadGeneration else {
                return .cancelled
            }
            failLoading(with: .cannotOpen)
            return .mediaFailure(.cannotOpen)
        }
        guard loadGeneration == mediaLoadGeneration else {
            return .cancelled
        }

        mediaSelection.refresh()
        mediaSelection.prepareExternalSubtitles(for: source.url)
        if presentation == .desktop || isSwitching(to: .desktop) {
            mediaSelection.suppressSubtitlesForDesktop()
        }

        duration = loadedDuration
        let canBeginNewPlayback =
            canAutoplayWhenLoaded
            && presentationGeneration == transitionGeneration
            && !isPlayerWindowDismissed
        let shouldRequestPlayback = autoplay
            && (isPlaybackRequested || canBeginNewPlayback)
        gate.setIntent(shouldRequestPlayback ? .playing : .paused)
        isPlaybackRequested = shouldRequestPlayback
        hasPlayableMedia = true

        if attachToPlayerSurface,
           presentation == .player,
           !isPlayerWindowDismissed,
           let playerSurface {
            do {
                try await engine.attach(to: playerSurface)
                try Task.checkCancellation()
                guard loadGeneration == mediaLoadGeneration else {
                    return .cancelled
                }
                if isPlayerWindowDismissed {
                    engine.detachAll()
                    attachedPlayerSurface = nil
                } else if isCurrentPlayerSurface(playerSurface) {
                    attachedPlayerSurface = playerSurface
                }
            } catch let error as PlaybackEngineError
                where error == .superseded {
                guard loadGeneration == mediaLoadGeneration else {
                    return .cancelled
                }
                // Window dismissal intentionally detaches a surface that may
                // still be waiting for its first frame. A reopen can arrive
                // before that stale attach reports `.superseded`; treat the
                // media load as successful and attach the current surface
                // again instead of leaving readiness stuck at `.loading`.
                readiness = .ready
                if presentation == .player,
                   !isPlayerWindowDismissed,
                   let currentPlayerSurface = self.playerSurface {
                    registerPlayerSurface(currentPlayerSurface)
                }
                applyPlaybackGate()
                return .loaded
            } catch is CancellationError {
                return .cancelled
            } catch let error as PlaybackEngineError {
                guard loadGeneration == mediaLoadGeneration else {
                    return .cancelled
                }
                if error == .surfaceTimeout {
                    handleRecoverablePlayerSurfaceFailure()
                    return .loaded
                }
                return handleGlobalLoadFailure(mapFailure(error))
            } catch {
                guard loadGeneration == mediaLoadGeneration else {
                    return .cancelled
                }
                handleRecoverablePlayerSurfaceFailure()
                return .loaded
            }
        }

        readiness = .ready
        if attachToPlayerSurface,
           presentation == .player,
           !isPlayerWindowDismissed,
           !isCurrentPlayerSurfaceAttached,
           let playerSurface {
            registerPlayerSurface(playerSurface)
        }
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
        let shouldCompleteFromEnd =
            intent == .playing
            && timelineSeekTarget == nil
            && isAtPlaybackEnd(currentTime)
        if intent == .playing, currentTime < duration {
            hasHandledCurrentItemEnd = false
        }
        gate.setIntent(intent)
        isPlaybackRequested = intent == .playing
        if shouldCompleteFromEnd {
            completeCurrentItem()
            return
        }
        applyPlaybackGate()
    }

    func beginTimelineSeek() {
        guard readiness == .ready, timelineSeekTarget == nil else {
            return
        }
        timelineSeekTarget = currentTime
        engine.pause()
        isActuallyPlaying = false
    }

    func endTimelineSeek() {
        guard let finalTarget = timelineSeekTarget else {
            return
        }
        timelineSeekTarget = nil
        guard readiness == .ready else {
            return
        }

        engine.seek(to: finalTarget, mode: .exact)

        if isPlaybackRequested, isAtPlaybackEnd(finalTarget) {
            completeCurrentItem()
        } else {
            applyPlaybackGate()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard readiness == .ready else {
            return
        }
        if timelineSeekTarget != nil {
            updateTimelineSeek(to: seconds)
            return
        }

        let clampedSeconds = min(max(seconds, 0), duration)
        if clampedSeconds < duration {
            hasHandledCurrentItemEnd = false
        }
        currentTime = clampedSeconds
        engine.seek(to: clampedSeconds, mode: .exact)
    }

    private func updateTimelineSeek(to seconds: TimeInterval) {
        guard readiness == .ready, timelineSeekTarget != nil else {
            return
        }

        let clampedSeconds = min(max(seconds, 0), duration)
        timelineSeekTarget = clampedSeconds
        if clampedSeconds < duration {
            hasHandledCurrentItemEnd = false
        }
        currentTime = clampedSeconds
        engine.seek(to: clampedSeconds, mode: .interactive)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setVolume(_ volume: PlaybackVolume) {
        let previousSettings = settings
        settings.setVolume(volume)
        guard settings != previousSettings else {
            return
        }
        savedPlayerSettings?.setVolume(volume)
        scheduleAudioPreferencesSave()
        guard presentation == .player else {
            return
        }
        applySettings(settings)
    }

    func adjustVolume(by delta: Float) {
        setVolume(
            PlaybackVolume(
                rawValue: settings.volume.rawValue + delta
            )
        )
    }

    func setMuted(_ isMuted: Bool) {
        let previousSettings = settings
        settings.setMuted(isMuted)
        guard settings != previousSettings else {
            return
        }
        savedPlayerSettings?.setMuted(isMuted)
        persistAudioPreferencesImmediately()
        guard presentation == .player else {
            return
        }
        applySettings(settings)
    }

    func setRate(_ rate: PlaybackRate) {
        guard presentation != .terminating,
              settings.rate != rate else {
            return
        }
        settings.rate = rate
        if savedPlayerSettings != nil {
            savedPlayerSettings?.rate = rate
        }
        preferencesStore?.savePlaybackRate(rate)
        applyPlaybackGate()
    }

    @discardableResult
    func beginTemporaryPlaybackRate(
        _ rate: PlaybackRate
    ) -> PlaybackRateOverrideToken? {
        guard temporaryPlaybackRate == nil,
              readiness == .ready,
              presentation == .player,
              isPlaybackRequested,
              !isPlayerWindowDismissed,
              !isSystemSuspended,
              !isDesktopEngineDetached,
              timelineSeekTarget == nil,
              !isWaitingForPlayerSurface else {
            return nil
        }

        let token = PlaybackRateOverrideToken()
        playbackRateOverrideToken = token
        temporaryPlaybackRate = rate
        applyPlaybackGate()
        return token
    }

    func endTemporaryPlaybackRate(
        _ token: PlaybackRateOverrideToken
    ) {
        guard playbackRateOverrideToken == token else {
            return
        }
        clearTemporaryPlaybackRateOverride()
        applyPlaybackGate()
    }

    func transitionToDesktop(_ surface: any PlaybackRenderSurface) async throws {
        guard canPresentOnDesktop else {
            throw PlaybackEngineError.superseded
        }

        cancelTimelineSeek()
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        transitionGeneration &+= 1
        let generation = transitionGeneration
        isDesktopEngineDetached = false
        presentation = .switching(generation: generation, destination: .desktop)
        savedPlayerSettings = settings
        mediaSelection.suppressSubtitlesForDesktop()

        // A Dock-menu desktop transition can begin while the player window is
        // hidden. Mute before releasing that visibility gate so the preserved
        // playing intent cannot briefly resume audible player playback.
        engine.setMuted(true)
        isPlayerWindowDismissed = false
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
            mediaSelection.restorePlayerSubtitleSelection()
            presentation = .player
            if let playerSurface, !isPlayerWindowDismissed {
                do {
                    try await engine.attach(to: playerSurface)
                    attachedPlayerSurface = playerSurface
                } catch {
                    attachedPlayerSurface = nil
                }
            }
            applyPlaybackGate()
            throw error
        }
    }

    func transitionToIndependentDesktop() async throws {
        guard canPresentOnDesktop else {
            throw PlaybackEngineError.superseded
        }

        try Task.checkCancellation()
        cancelTimelineSeek()
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        transitionGeneration &+= 1
        let generation = transitionGeneration
        presentation = .switching(
            generation: generation,
            destination: .desktop
        )
        savedPlayerSettings = settings
        mediaSelection.suppressSubtitlesForDesktop()

        // Independent display engines own every desktop render surface. Keep
        // the foreground engine's queue, time, and intent intact while making
        // it completely inert until the player window is restored.
        engine.setMuted(true)
        engine.pause()
        engine.detachAll()
        isActuallyPlaying = false
        isPlayerWindowDismissed = false

        try Task.checkCancellation()
        guard generation == transitionGeneration else {
            throw PlaybackEngineError.superseded
        }
        isDesktopEngineDetached = true
        presentation = .desktop
        applyPlaybackGate()
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
        applyPlaybackGate()

        do {
            try await engine.attach(to: playerSurface)
            try Task.checkCancellation()
            guard generation == transitionGeneration else {
                throw PlaybackEngineError.superseded
            }
            attachedPlayerSurface = playerSurface
            isDesktopEngineDetached = false
            restorePlayerSettings()
            mediaSelection.restorePlayerSubtitleSelection()
            presentation = .player
            applyPlaybackGate()
        } catch {
            guard presentation != .terminating,
                  generation == transitionGeneration else {
                throw error
            }
            presentation = .desktop
            applyPlaybackGate()
            throw error
        }
    }

    func setSuspended(_ suspended: Bool, for reason: PlaybackSuspensionReason) {
        guard gate.setSuspended(suspended, for: reason) else {
            return
        }
        updatePublishedSuspensionState()
        updateProgressCadence()
        applyPlaybackGate()
    }

    func dismissPlayerWindow() {
        guard presentation != .terminating else {
            return
        }

        cancelTimelineSeek()
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        isPlayerWindowDismissed = true
        attachedPlayerSurface = nil
        restorePlayerSettings()
        mediaSelection.restorePlayerSubtitleSelection()
        presentation = .player
        isDesktopEngineDetached = false
        engine.pause()
        engine.detachAll()
        isActuallyPlaying = false
    }

    func restorePlayerWindow() {
        guard presentation != .terminating else {
            return
        }

        isPlayerWindowDismissed = false
        guard presentation == .player else {
            applyPlaybackGate()
            return
        }

        if case .failed(.surfaceTimeout) = readiness,
           source != nil,
           hasPlayableMedia {
            readiness = .ready
        }
        guard readiness == .ready,
              let playerSurface else {
            applyPlaybackGate()
            return
        }

        registerPlayerSurface(playerSurface)
    }

    func stop() {
        cancelTimelineSeek()
        clearTemporaryPlaybackRateOverride()
        mediaSelection.reset()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        transitionGeneration &+= 1
        mediaLoadGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        source = nil
        hasPlayableMedia = false
        readiness = .empty
        presentation = .player
        isDesktopEngineDetached = false
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    func loadExternalSubtitle(_ subtitleURL: URL) {
        guard hasPlayableMedia,
              let mediaURL = source?.url else {
            return
        }
        mediaSelection.loadExternalSubtitle(
            subtitleURL,
            for: mediaURL
        )
    }

    func shutdown() {
        flushPendingAudioPreferences()
        guard presentation != .terminating else {
            return
        }
        cancelTimelineSeek()
        clearTemporaryPlaybackRateOverride()
        mediaSelection.reset()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        transitionGeneration &+= 1
        mediaLoadGeneration &+= 1
        presentation = .terminating
        isDesktopEngineDetached = false
        gate.terminate()
        isSystemSuspended = false
        isPlayerWindowDismissed = true
        isActuallyPlaying = false
        isPlaybackRequested = false
        engine.stop()
        playerSurface = nil
        source = nil
        hasPlayableMedia = false
    }

    func finishQueue(with failure: PlaybackFailure) {
        fail(with: failure)
        playbackFailureHandler?(failure)
    }

    private func applyPlaybackGate() {
        if !canMaintainTemporaryPlaybackRateOverride {
            clearTemporaryPlaybackRateOverride()
        }
        guard readiness == .ready,
              !isPlayerWindowDismissed,
              timelineSeekTarget == nil,
              !isDesktopEngineDetached,
              !isWaitingForPlayerSurface else {
            engine.pause()
            isActuallyPlaying = false
            return
        }

        if shouldPlayForCurrentPresentation {
            engine.play(at: temporaryPlaybackRate ?? settings.rate)
        } else {
            engine.pause()
            isActuallyPlaying = false
        }
    }

    private func applySettings(_ settings: PlaybackSettings) {
        engine.setVolume(settings.volume)
        engine.setMuted(settings.isMuted)
    }

    private func scheduleAudioPreferencesSave() {
        guard preferencesStore != nil else {
            return
        }

        pendingAudioPreferences = currentAudioPreferences
        audioPreferencesSaveTask?.cancel()
        let persistenceDelay = audioPreferencesPersistenceDelay
        audioPreferencesSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: persistenceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.commitPendingAudioPreferences()
        }
    }

    private func persistAudioPreferencesImmediately() {
        audioPreferencesSaveTask?.cancel()
        audioPreferencesSaveTask = nil
        pendingAudioPreferences = nil
        preferencesStore?.saveAudio(currentAudioPreferences)
    }

    private func flushPendingAudioPreferences() {
        audioPreferencesSaveTask?.cancel()
        audioPreferencesSaveTask = nil
        commitPendingAudioPreferences()
    }

    private func commitPendingAudioPreferences() {
        audioPreferencesSaveTask = nil
        guard let pendingAudioPreferences else {
            return
        }
        self.pendingAudioPreferences = nil
        preferencesStore?.saveAudio(pendingAudioPreferences)
    }

    private var currentAudioPreferences: PlaybackAudioPreferences {
        PlaybackAudioPreferences(
            volume: settings.volume,
            isMuted: settings.isMuted,
            restorableVolume: settings.restorableVolume
        )
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

    private func handleProgress(_ seconds: TimeInterval) {
        guard appliedProgressCadence != .inactive,
              timelineSeekTarget == nil else {
            return
        }
        currentTime = seconds
    }

    private func handleItemEnded() {
        guard isPlaybackRequested, timelineSeekTarget == nil else {
            return
        }
        completeCurrentItem()
    }

    private func completeCurrentItem() {
        guard !hasHandledCurrentItemEnd else {
            return
        }
        hasHandledCurrentItemEnd = true

        let disposition = itemEndedHandler?() ?? .unhandled
        if disposition == .advanced {
            return
        }

        if disposition == .repeatCurrent {
            restartCurrentItemAfterCompletion()
            return
        }

        guard presentation == .desktop else {
            gate.setIntent(.paused)
            isPlaybackRequested = false
            engine.seek(to: 0)
            currentTime = 0
            hasHandledCurrentItemEnd = false
            applyPlaybackGate()
            return
        }

        engine.seek(to: 0)
        currentTime = 0
        hasHandledCurrentItemEnd = false
        applyPlaybackGate()
    }

    private func restartCurrentItemAfterCompletion() {
        engine.seek(to: 0)
        currentTime = 0
        hasHandledCurrentItemEnd = false
        applyPlaybackGate()
    }

    private func fail(with failure: PlaybackFailure) {
        cancelTimelineSeek()
        clearTemporaryPlaybackRateOverride()
        mediaSelection.reset()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        attachedPlayerSurface = nil
        transitionGeneration &+= 1
        mediaLoadGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        hasPlayableMedia = false
        readiness = .failed(failure)
        presentation = .player
        isDesktopEngineDetached = false
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    private func failLoading(with failure: PlaybackFailure) {
        cancelTimelineSeek()
        clearTemporaryPlaybackRateOverride()
        mediaSelection.reset()
        hasHandledCurrentItemEnd = false
        engine.pause()
        readiness = .failed(failure)
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
    }

    private func handleEngineFailure(_ error: PlaybackEngineError) {
        let failure = mapFailure(error)
        cancelTimelineSeek()
        hasHandledCurrentItemEnd = false
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

    private func handleRecoverablePlayerSurfaceFailure() {
        attachedPlayerSurface = nil
        engine.pause()
        readiness = .failed(.surfaceTimeout)
        isActuallyPlaying = false
        playbackFailureHandler?(.surfaceTimeout)
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
        playerSurfaceAttachmentGeneration &+= 1
        playerSurfaceAttachmentTask?.cancel()
        playerSurfaceAttachmentTask = nil
        attachingPlayerSurface = nil
    }

    private var canMaintainTemporaryPlaybackRateOverride: Bool {
        readiness == .ready
            && presentation == .player
            && isPlaybackRequested
            && !isPlayerWindowDismissed
            && !isSystemSuspended
            && !isDesktopEngineDetached
            && timelineSeekTarget == nil
            && !isWaitingForPlayerSurface
    }

    private func clearTemporaryPlaybackRateOverride() {
        playbackRateOverrideToken = nil
        temporaryPlaybackRate = nil
    }

    private func finishPlayerSurfaceAttachment(generation: UInt64) {
        guard generation == playerSurfaceAttachmentGeneration else {
            return
        }
        playerSurfaceAttachmentTask = nil
        attachingPlayerSurface = nil
    }

    private func cancelTimelineSeek() {
        timelineSeekTarget = nil
    }

    private func updateProgressCadence() {
        let cadence = desiredProgressCadence
        guard cadence != appliedProgressCadence else {
            return
        }
        appliedProgressCadence = cadence
        engine.setProgressCadence(cadence)
    }

    private func updatePublishedSuspensionState() {
        let nextSuspensionState = hasBlockingSuspensionForCurrentPresentation
        if isSystemSuspended != nextSuspensionState {
            isSystemSuspended = nextSuspensionState
        }
    }

    private var desiredProgressCadence: PlaybackProgressCadence {
        guard readiness == .ready,
              !isPlayerWindowDismissed,
              !hasBlockingSuspensionForCurrentPresentation else {
            return .inactive
        }

        switch presentation {
        case .player:
            return .visible
        case .switching(_, .player) where isDesktopEngineDetached:
            return .inactive
        case .desktop where isDesktopEngineDetached:
            return .inactive
        case .switching, .desktop:
            return .background
        case .terminating:
            return .inactive
        }
    }

    private var shouldPlayForCurrentPresentation: Bool {
        gate.shouldPlay(ignoring: ignoredSuspensionReasonsForCurrentPresentation)
    }

    private var isWaitingForPlayerSurface: Bool {
        guard playerSurface != nil else {
            return false
        }
        switch presentation {
        case .player, .switching(_, .player):
            return !isCurrentPlayerSurfaceAttached
        case .switching(_, .desktop), .desktop, .terminating:
            return false
        }
    }

    private var isCurrentPlayerSurfaceAttached: Bool {
        guard let playerSurface,
              let attachedPlayerSurface else {
            return false
        }
        return attachedPlayerSurface === playerSurface
    }

    private var hasBlockingSuspensionForCurrentPresentation: Bool {
        !gate.suspensionReasons.isSubset(
            of: ignoredSuspensionReasonsForCurrentPresentation
        )
    }

    private var ignoredSuspensionReasonsForCurrentPresentation: Set<
        PlaybackSuspensionReason
    > {
        let scope = currentPresentationScope
        return Set(gate.suspensionReasons.filter { reason in
            switch (reason.scope, scope) {
            case (.allPresentations, _):
                false
            case (.desktopOnly, .playerOnly),
                 (.playerOnly, .desktopOnly):
                true
            case (.desktopOnly, .desktopOnly),
                 (.playerOnly, .playerOnly),
                 (.desktopOnly, .allPresentations),
                 (.playerOnly, .allPresentations):
                false
            }
        })
    }

    private var currentPresentationScope: PlaybackSuspensionScope {
        switch presentation {
        case let .switching(_, destination):
            return destination == .desktop ? .desktopOnly : .playerOnly
        case .desktop:
            return .desktopOnly
        case .player, .terminating:
            return .playerOnly
        }
    }

    private func isAtPlaybackEnd(_ target: TimeInterval) -> Bool {
        duration > 0 && target >= duration
    }

    private func isCurrentPlayerSurface(
        _ surface: any PlaybackRenderSurface
    ) -> Bool {
        guard let playerSurface else {
            return false
        }
        return playerSurface === surface
    }

    private func isSameSurface(
        _ lhs: (any PlaybackRenderSurface)?,
        _ rhs: any PlaybackRenderSurface
    ) -> Bool {
        guard let lhs else {
            return false
        }
        return lhs === rhs
    }
}
