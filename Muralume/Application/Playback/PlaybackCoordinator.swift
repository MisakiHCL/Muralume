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
    @Published private(set) var hasPlayableMedia = false
    @Published private(set) var settings: PlaybackSettings
    @Published private(set) var isPlayerWindowDismissed = false

    var canPresentOnDesktop: Bool {
        readiness == .ready
            && presentation == .player
            && !isPlayerWindowDismissed
    }

    var isSystemSuspended: Bool {
        isDesktopPresentationRelevant && !gate.suspensionReasons.isEmpty
    }

    private let engine: any PlaybackEngine
    private let preferencesStore: (any AppPreferencesStoring)?
    private let audioPreferencesPersistenceDelay: Duration
    private var gate = PlaybackGate()
    private weak var playerSurface: (any PlaybackRenderSurface)?
    private var playerSurfaceAttachmentTask: Task<Void, Never>?
    private var audioPreferencesSaveTask: Task<Void, Never>?
    private var pendingAudioPreferences: PlaybackAudioPreferences?
    private var savedPlayerSettings: PlaybackSettings?
    private var transitionGeneration: UInt64 = 0
    private var timelineSeekTarget: TimeInterval?
    private var hasHandledCurrentItemEnd = false

    init(
        engine: any PlaybackEngine,
        initialPreferences: AppPreferences = .defaultValue,
        preferencesStore: (any AppPreferencesStoring)? = nil,
        audioPreferencesPersistenceDelay: Duration =
            PlaybackPolicy.audioPreferencesPersistenceDelay
    ) {
        self.engine = engine
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
        applySettings(settings)
    }

    deinit {
        audioPreferencesSaveTask?.cancel()
    }

    func registerPlayerSurface(_ surface: any PlaybackRenderSurface) {
        cancelPlayerSurfaceAttachment()
        playerSurface = surface
        guard presentation == .player,
              readiness == .ready,
              !isPlayerWindowDismissed else {
            return
        }
        let expectedGeneration = transitionGeneration

        playerSurfaceAttachmentTask = Task { [weak self] in
            guard let self,
                  presentation == .player,
                  readiness == .ready,
                  !isPlayerWindowDismissed,
                  isCurrentPlayerSurface(surface),
                  transitionGeneration == expectedGeneration else {
                return
            }
            do {
                try await engine.attach(to: surface)
                try Task.checkCancellation()
                guard presentation == .player,
                      readiness == .ready,
                      !isPlayerWindowDismissed,
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
                      readiness == .ready,
                      !isPlayerWindowDismissed else {
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

        cancelTimelineSeek()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        let loadGeneration = transitionGeneration
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
            return handleLoadFailure(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            failLoading(with: .cannotOpen)
            return .mediaFailure(.cannotOpen)
        }

        duration = loadedDuration
        if presentation == .player,
           !isPlayerWindowDismissed,
           let playerSurface {
            do {
                try await engine.attach(to: playerSurface)
                try Task.checkCancellation()
                if isPlayerWindowDismissed {
                    engine.detachAll()
                }
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

        hasPlayableMedia = true
        readiness = .ready
        let shouldAutoplay = autoplay
            && canAutoplayWhenLoaded
            && loadGeneration == transitionGeneration
            && !isPlayerWindowDismissed
        gate.setIntent(shouldAutoplay ? .playing : .paused)
        isPlaybackRequested = shouldAutoplay
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
        let clampedSeconds = min(max(seconds, 0), duration)
        if timelineSeekTarget != nil {
            timelineSeekTarget = clampedSeconds
        }
        if clampedSeconds < duration {
            hasHandledCurrentItemEnd = false
        }
        currentTime = clampedSeconds
        engine.seek(to: clampedSeconds)
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

    func transitionToDesktop(_ surface: any PlaybackRenderSurface) async throws {
        guard canPresentOnDesktop else {
            return
        }

        cancelTimelineSeek()
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
            if let playerSurface, !isPlayerWindowDismissed {
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

    func dismissPlayerWindow() {
        guard presentation != .terminating else {
            return
        }

        cancelTimelineSeek()
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        isPlayerWindowDismissed = true
        gate.setIntent(.paused)
        isPlaybackRequested = false
        restorePlayerSettings()
        presentation = .player
        engine.pause()
        engine.detachAll()
        isActuallyPlaying = false
    }

    func restorePlayerWindow() {
        guard presentation != .terminating else {
            return
        }

        isPlayerWindowDismissed = false
        guard presentation == .player,
              readiness == .ready,
              let playerSurface else {
            applyPlaybackGate()
            return
        }

        registerPlayerSurface(playerSurface)
        applyPlaybackGate()
    }

    func stop() {
        cancelTimelineSeek()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        source = nil
        hasPlayableMedia = false
        readiness = .empty
        presentation = .player
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    func shutdown() {
        flushPendingAudioPreferences()
        guard presentation != .terminating else {
            return
        }
        cancelTimelineSeek()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        presentation = .terminating
        gate.terminate()
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
        guard readiness == .ready,
              !isPlayerWindowDismissed,
              timelineSeekTarget == nil else {
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
        guard timelineSeekTarget == nil else {
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

        if itemEndedHandler?() == true {
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

    private func fail(with failure: PlaybackFailure) {
        cancelTimelineSeek()
        hasHandledCurrentItemEnd = false
        cancelPlayerSurfaceAttachment()
        transitionGeneration &+= 1
        gate.setIntent(.paused)
        restorePlayerSettings()
        engine.stop()
        hasPlayableMedia = false
        readiness = .failed(failure)
        presentation = .player
        currentTime = 0
        duration = 0
        isActuallyPlaying = false
        isPlaybackRequested = false
        savedPlayerSettings = nil
    }

    private func failLoading(with failure: PlaybackFailure) {
        cancelTimelineSeek()
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

    private func cancelTimelineSeek() {
        timelineSeekTarget = nil
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
