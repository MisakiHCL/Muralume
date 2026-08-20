import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class TestPlaybackSurface: PlaybackRenderSurface {
    let id: PlaybackSurfaceID
    var isReadyForDisplay = true

    init(id: PlaybackSurfaceID) {
        self.id = id
    }
}

@MainActor
final class TestAVPlayerSurface: AVPlayerRenderSurface {
    let id: PlaybackSurfaceID
    var isReadyForDisplay = true
    private(set) var isConnected = false

    init(id: PlaybackSurfaceID) {
        self.id = id
    }

    func connect(to player: AVPlayer?) {
        isConnected = player != nil
    }
}

@MainActor
final class TestPlaybackEngine: PlaybackEngine {
    enum PlaybackEvent: Equatable {
        case play
        case seek(TimeInterval)
    }

    private enum TestPolicy {
        static let blockedAttachmentNanoseconds: UInt64 = 5_000_000_000
    }

    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?
    var externalSubtitleTimeHandler: ((TimeInterval) -> Void)?
    var embeddedSubtitleCueHandler: ((String?) -> Void)?
    private(set) var attachedSurfaceIDs: [PlaybackSurfaceID] = []
    private(set) var attachmentReadinessPolicies:
        [PlaybackSurfaceReadinessPolicy] = []
    private(set) var attachedSurfaceID: PlaybackSurfaceID?
    private(set) var isPlaying = false
    private(set) var volume = PlaybackVolume.full
    private(set) var isMuted = false
    private(set) var rate = PlaybackPolicy.defaultRate
    private(set) var loadedSources: [ResolvedMediaSource] = []
    private(set) var soughtTimes: [TimeInterval] = []
    private(set) var seekModes: [PlaybackSeekMode] = []
    private(set) var progressCadence: PlaybackProgressCadence = .inactive
    private(set) var progressCadenceChanges: [PlaybackProgressCadence] = []
    var mediaSelectionState: PlaybackMediaSelectionState = .empty
    private(set) var audioSelections: [PlaybackAudioSelection] = []
    private(set) var subtitleSelections: [PlaybackSubtitleSelection] = []
    private(set) var stopCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var playbackEvents: [PlaybackEvent] = []
    var loadErrorsByURL: [URL: PlaybackEngineError] = [:]
    var attachmentErrorsBySurfaceID: [PlaybackSurfaceID: PlaybackEngineError] = [:]
    var shouldBlockLoads = false
    var shouldBlockAttachments = false
    var blockedAttachmentError: PlaybackEngineError?
    private(set) var didBeginBlockedLoad = false
    private(set) var didBeginBlockedAttachment = false
    private var blockedLoadContinuation:
        CheckedContinuation<TimeInterval, any Error>?

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        loadedSources.append(source)
        if let error = loadErrorsByURL[source.url] {
            throw error
        }
        if shouldBlockLoads {
            didBeginBlockedLoad = true
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedLoadContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelBlockedLoad()
                }
            }
        }
        return 120
    }

    func finishBlockedLoad(duration: TimeInterval = 120) {
        blockedLoadContinuation?.resume(returning: duration)
        blockedLoadContinuation = nil
    }

    private func cancelBlockedLoad() {
        blockedLoadContinuation?.resume(throwing: CancellationError())
        blockedLoadContinuation = nil
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        try await attach(to: surface, readinessPolicy: .required)
    }

    func attach(
        to surface: any PlaybackRenderSurface,
        readinessPolicy: PlaybackSurfaceReadinessPolicy
    ) async throws {
        attachedSurfaceIDs.append(surface.id)
        attachmentReadinessPolicies.append(readinessPolicy)
        if let error = attachmentErrorsBySurfaceID[surface.id] {
            attachedSurfaceID = nil
            throw error
        }
        attachedSurfaceID = surface.id
        if shouldBlockAttachments, readinessPolicy == .required {
            didBeginBlockedAttachment = true
            try await Task.sleep(
                nanoseconds: TestPolicy.blockedAttachmentNanoseconds
            )
            if let blockedAttachmentError {
                self.blockedAttachmentError = nil
                shouldBlockAttachments = false
                attachedSurfaceID = nil
                throw blockedAttachmentError
            }
        }
    }

    func detachAll() {
        attachedSurfaceID = nil
    }

    func play(at rate: PlaybackRate) {
        playCount += 1
        playbackEvents.append(.play)
        self.rate = rate
        isPlaying = true
        playbackActivityHandler?(true)
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {
        seek(to: seconds, mode: .exact)
    }

    func seek(to seconds: TimeInterval, mode: PlaybackSeekMode) {
        soughtTimes.append(seconds)
        seekModes.append(mode)
        playbackEvents.append(.seek(seconds))
    }

    func resetPlaybackEvents() {
        playbackEvents.removeAll()
    }

    func setProgressCadence(_ cadence: PlaybackProgressCadence) {
        progressCadence = cadence
        progressCadenceChanges.append(cadence)
    }

    func setVolume(_ volume: PlaybackVolume) {
        self.volume = volume
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    func currentMediaSelectionState() -> PlaybackMediaSelectionState {
        mediaSelectionState
    }

    func selectAudio(
        _ selection: PlaybackAudioSelection
    ) -> PlaybackMediaSelectionState {
        let effectiveOptionID: PlaybackMediaOptionID?
        switch selection {
        case .automatic:
            effectiveOptionID = mediaSelectionState.effectiveAudioOptionID
        case let .option(id):
            guard mediaSelectionState.audioOptions.contains(
                where: { $0.id == id }
            ) else {
                return mediaSelectionState
            }
            effectiveOptionID = id
        }
        audioSelections.append(selection)
        mediaSelectionState = PlaybackMediaSelectionState(
            audioOptions: mediaSelectionState.audioOptions,
            subtitleOptions: mediaSelectionState.subtitleOptions,
            audioSelection: selection,
            subtitleSelection: mediaSelectionState.subtitleSelection,
            effectiveAudioOptionID: effectiveOptionID,
            effectiveSubtitleOptionID:
                mediaSelectionState.effectiveSubtitleOptionID,
            allowsEmptySubtitleSelection:
                mediaSelectionState.allowsEmptySubtitleSelection
        )
        return mediaSelectionState
    }

    func selectSubtitles(
        _ selection: PlaybackSubtitleSelection
    ) -> PlaybackMediaSelectionState {
        let effectiveOptionID: PlaybackMediaOptionID?
        switch selection {
        case .automatic:
            effectiveOptionID = mediaSelectionState
                .effectiveSubtitleOptionID
        case .off:
            guard mediaSelectionState.allowsEmptySubtitleSelection else {
                return mediaSelectionState
            }
            effectiveOptionID = nil
        case let .option(id):
            guard mediaSelectionState.subtitleOptions.contains(
                where: { $0.id == id }
            ) else {
                return mediaSelectionState
            }
            effectiveOptionID = id
        }
        subtitleSelections.append(selection)
        mediaSelectionState = PlaybackMediaSelectionState(
            audioOptions: mediaSelectionState.audioOptions,
            subtitleOptions: mediaSelectionState.subtitleOptions,
            audioSelection: mediaSelectionState.audioSelection,
            subtitleSelection: selection,
            effectiveAudioOptionID:
                mediaSelectionState.effectiveAudioOptionID,
            effectiveSubtitleOptionID: effectiveOptionID,
            allowsEmptySubtitleSelection:
                mediaSelectionState.allowsEmptySubtitleSelection
        )
        return mediaSelectionState
    }

    func setExternalSubtitleTimeHandler(
        _ handler: ((TimeInterval) -> Void)?
    ) {
        externalSubtitleTimeHandler = handler
    }

    func setEmbeddedSubtitleCueHandler(
        _ handler: ((String?) -> Void)?
    ) {
        embeddedSubtitleCueHandler = handler
    }

    func publishExternalSubtitleTime(_ time: TimeInterval) {
        externalSubtitleTimeHandler?(time)
    }

    func stop() {
        stopCount += 1
        attachedSurfaceID = nil
        isPlaying = false
        externalSubtitleTimeHandler = nil
        embeddedSubtitleCueHandler?(nil)
        mediaSelectionState = .empty
        playbackActivityHandler?(false)
    }

    func emitFailure(_ error: PlaybackEngineError) {
        failureHandler?(error)
    }

    func emitItemEnded() {
        itemEndedHandler?()
    }
}

@MainActor
final class TestAppPreferencesStore: AppPreferencesStoring {
    let preferences: AppPreferences
    private(set) var loadCount = 0
    private(set) var savedAudio: [PlaybackAudioPreferences] = []
    private(set) var savedPlaybackRates: [PlaybackRate] = []
    private(set) var savedPlaybackOrders: [PlaybackOrder] = []
    private(set) var savedPlaybackRepeatBehaviors:
        [PlaybackRepeatBehavior] = []
    private(set) var savedLibrarySorts: [MediaLibrarySort] = []
    private(set) var savedLanguages: [AppLanguage] = []
    private(set) var savedSubtitleAppearances:
        [SubtitleAppearancePreferences] = []
    private(set) var savedSmartPausePreferences: [SmartPausePreferences] = []

    init(preferences: AppPreferences = .defaultValue) {
        self.preferences = preferences
    }

    func load() -> AppPreferences {
        loadCount += 1
        return preferences
    }

    func saveAudio(_ audio: PlaybackAudioPreferences) {
        savedAudio.append(audio)
    }

    func savePlaybackRate(_ rate: PlaybackRate) {
        savedPlaybackRates.append(rate)
    }

    func savePlaybackOrder(_ order: PlaybackOrder) {
        savedPlaybackOrders.append(order)
    }

    func savePlaybackRepeatBehavior(
        _ behavior: PlaybackRepeatBehavior
    ) {
        savedPlaybackRepeatBehaviors.append(behavior)
    }

    func saveLibrarySort(_ sort: MediaLibrarySort) {
        savedLibrarySorts.append(sort)
    }

    func saveLanguage(_ language: AppLanguage) {
        savedLanguages.append(language)
    }

    func saveSubtitleAppearance(
        _ preferences: SubtitleAppearancePreferences
    ) {
        savedSubtitleAppearances.append(preferences)
    }

    func saveSmartPause(_ preferences: SmartPausePreferences) {
        savedSmartPausePreferences.append(preferences)
    }
}

@MainActor
final class TestDefaultVideoPlayerService: DefaultVideoPlayerServicing {
    var status: DefaultVideoPlayerStatus
    var setDefaultError: Error?
    private(set) var setDefaultCount = 0

    init(status: DefaultVideoPlayerStatus = .none) {
        self.status = status
    }

    func setAsDefault() async throws {
        setDefaultCount += 1
        if let setDefaultError {
            throw setDefaultError
        }
        status = .all
    }
}

enum TestMediaFixture {
    static let duration: TimeInterval = 20
    static let readinessProbeNanoseconds: UInt64 = 50_000_000
    static let frameProbeTime: TimeInterval = 0.5
    static let timeScale: CMTimeScale = 600
    static let minimumVisibleBrightness: CGFloat = 0.2
    static let minimumVisibleSaturation: CGFloat = 0.2
    static let samplePoints: [(x: Int, y: Int)] = [
        (40, 40),
        (160, 90),
        (280, 140)
    ]

    static func h264URL(for testClass: AnyClass) throws -> URL {
        try XCTUnwrap(
            Bundle(for: testClass).url(
                forResource: "landscape-20s-h264",
                withExtension: "mp4"
            )
        )
    }
}

@MainActor
final class TestDesktopHost: DesktopHosting {
    var desktopOcclusionHandler: ((Bool) -> Void)?
    var desktopVisibilityHandler: (
        ([DesktopDisplayID: DesktopVisibilityState]) -> Void
    )?
    var revealHandler: (() -> Void)?
    let surface = TestPlaybackSurface(id: .desktop)
    var scenePreparation: DesktopHostPreparation?
    private var displaySurfaceEventHandler:
        ((DesktopDisplaySurfaceEvent) -> Void)?
    private(set) var prepareCount = 0
    private(set) var preparedContentModes: [DesktopVideoContentMode] = []
    private(set) var appliedContentModes: [DesktopVideoContentMode] = []
    private(set) var appliedEnergyConstraints: [Bool] = []
    private(set) var revealCount = 0
    private(set) var reassertCount = 0
    private(set) var closeCount = 0

    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface {
        prepareCount += 1
        preparedContentModes.append(contentMode)
        return surface
    }

    func prepare(scene: DesktopScene) -> DesktopHostPreparation {
        if let scenePreparation {
            prepareCount += 1
            preparedContentModes.append(scene.defaultContentMode)
            return scenePreparation
        }
        return DesktopHostPreparation(
            synchronizedSurface: prepare(
                contentMode: scene.defaultContentMode
            ),
            displaySurfaces: [:]
        )
    }

    func setDisplaySurfaceEventHandler(
        _ handler: ((DesktopDisplaySurfaceEvent) -> Void)?
    ) {
        displaySurfaceEventHandler = handler
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        appliedContentModes.append(contentMode)
    }

    func setEnergyConstrained(_ isEnergyConstrained: Bool) {
        appliedEnergyConstraints.append(isEnergyConstrained)
    }

    func reveal() {
        revealCount += 1
        revealHandler?()
    }

    func reassertDesktopPlacement() {
        reassertCount += 1
    }

    func close() {
        closeCount += 1
    }

    func emitDesktopOcclusion(_ isOccluded: Bool) {
        desktopOcclusionHandler?(isOccluded)
        emitDesktopVisibility([
            DesktopDisplayID(rawValue: "test-display"):
                isOccluded ? .occluded : .visible
        ])
    }

    func emitDesktopVisibility(
        _ states: [DesktopDisplayID: DesktopVisibilityState]
    ) {
        desktopVisibilityHandler?(states)
    }

    func emitDisplaySurfaceEvent(_ event: DesktopDisplaySurfaceEvent) {
        displaySurfaceEventHandler?(event)
    }
}

@MainActor
final class TestDesktopStatusPresenter: DesktopStatusPresenting {
    var stateProvider: (() -> DesktopStatusState)?
    var togglePlaybackHandler: (() -> Void)?
    var playNextHandler: (() -> Void)?
    var setPlaybackOrderHandler: ((PlaybackOrder) -> Void)?
    var setPlaybackModeHandler: ((PlaybackMode) -> Void)?
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)?
    var returnToPlayerHandler: (() -> Void)?
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)?
    var quitHandler: (() -> Void)?
    var showHandler: (() -> Void)?
    var showResult = true
    private(set) var showCount = 0
    private(set) var removeCount = 0

    @discardableResult
    func show() -> Bool {
        showCount += 1
        showHandler?()
        return showResult
    }

    func remove() {
        removeCount += 1
    }
}

@MainActor
final class TestApplicationPresenceController: ApplicationPresenceControlling {
    var setModeHandler: ((ApplicationPresenceMode) -> Void)?
    private(set) var appliedModes: [ApplicationPresenceMode] = []
    var results: [Bool]

    init(results: [Bool] = []) {
        self.results = results
    }

    @discardableResult
    func setMode(_ mode: ApplicationPresenceMode) -> Bool {
        appliedModes.append(mode)
        setModeHandler?(mode)
        guard !results.isEmpty else {
            return true
        }
        return results.removeFirst()
    }
}

final class TestDesktopVideoContentModeStore: DesktopVideoContentModeStoring {
    private(set) var contentMode: DesktopVideoContentMode
    private(set) var savedContentModes: [DesktopVideoContentMode] = []

    init(contentMode: DesktopVideoContentMode = .defaultValue) {
        self.contentMode = contentMode
    }

    func load() -> DesktopVideoContentMode {
        contentMode
    }

    func save(_ contentMode: DesktopVideoContentMode) {
        self.contentMode = contentMode
        savedContentModes.append(contentMode)
    }
}

@MainActor
final class TestSystemLifecycleMonitor: SystemLifecycleMonitoring {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)?
    var energyConstraintsHandler: (
        (Set<SystemEnergyConstraintReason>) -> Void
    )?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var desktopMonitoringStates: [Bool] = []

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setDesktopMonitoringActive(_ isActive: Bool) {
        desktopMonitoringStates.append(isActive)
    }

    func emit(_ reason: PlaybackSuspensionReason, suspended: Bool) {
        suspensionHandler?(reason, suspended)
    }

    func emitEnergyConstrained(_ isEnergyConstrained: Bool) {
        emitEnergyConstraints(
            isEnergyConstrained ? [.lowPowerMode] : []
        )
    }

    func emitEnergyConstraints(
        _ constraints: Set<SystemEnergyConstraintReason>
    ) {
        energyConstraintsHandler?(constraints)
    }
}

@MainActor
final class TestMainWindowPresenter: MainWindowPresenting {
    var hideHandler: (() -> Void)?
    private(set) var hideCount = 0
    private(set) var prepareForReturnCount = 0
    private(set) var showCount = 0
    private(set) var hideAfterFailedReturnCount = 0
    private(set) var dismissCount = 0
    private(set) var minimizeCount = 0
    private(set) var toggleFullScreenCount = 0

    func hide() {
        hideCount += 1
        hideHandler?()
    }

    func prepareForReturn() {
        prepareForReturnCount += 1
    }

    func show() {
        showCount += 1
    }

    func hideAfterFailedReturn() {
        hideAfterFailedReturnCount += 1
    }

    func toggleFullScreen() {
        toggleFullScreenCount += 1
    }

    func dismiss() {
        dismissCount += 1
    }

    func minimize() {
        minimizeCount += 1
    }
}
