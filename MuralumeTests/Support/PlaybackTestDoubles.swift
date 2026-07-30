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
    private enum TestPolicy {
        static let blockedAttachmentNanoseconds: UInt64 = 5_000_000_000
    }

    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?
    private(set) var attachedSurfaceIDs: [PlaybackSurfaceID] = []
    private(set) var attachedSurfaceID: PlaybackSurfaceID?
    private(set) var isPlaying = false
    private(set) var volume = PlaybackVolume.full
    private(set) var isMuted = false
    private(set) var rate = PlaybackPolicy.defaultRate
    private(set) var loadedSources: [ResolvedMediaSource] = []
    private(set) var soughtTimes: [TimeInterval] = []
    var loadErrorsByURL: [URL: PlaybackEngineError] = [:]
    var shouldBlockLoads = false
    var shouldBlockAttachments = false
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
            return try await withCheckedThrowingContinuation { continuation in
                blockedLoadContinuation = continuation
            }
        }
        return 120
    }

    func finishBlockedLoad(duration: TimeInterval = 120) {
        blockedLoadContinuation?.resume(returning: duration)
        blockedLoadContinuation = nil
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        attachedSurfaceIDs.append(surface.id)
        attachedSurfaceID = surface.id
        if shouldBlockAttachments {
            didBeginBlockedAttachment = true
            try await Task.sleep(
                nanoseconds: TestPolicy.blockedAttachmentNanoseconds
            )
        }
    }

    func detachAll() {
        attachedSurfaceID = nil
    }

    func play(at rate: PlaybackRate) {
        self.rate = rate
        isPlaying = true
        playbackActivityHandler?(true)
    }

    func pause() {
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {
        soughtTimes.append(seconds)
    }

    func setVolume(_ volume: PlaybackVolume) {
        self.volume = volume
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    func stop() {
        attachedSurfaceID = nil
        isPlaying = false
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
    private(set) var savedLibrarySorts: [MediaLibrarySort] = []
    private(set) var savedLanguages: [AppLanguage] = []

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

    func saveLibrarySort(_ sort: MediaLibrarySort) {
        savedLibrarySorts.append(sort)
    }

    func saveLanguage(_ language: AppLanguage) {
        savedLanguages.append(language)
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
    let surface = TestPlaybackSurface(id: .desktop)
    private(set) var prepareCount = 0
    private(set) var preparedContentModes: [DesktopVideoContentMode] = []
    private(set) var appliedContentModes: [DesktopVideoContentMode] = []
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

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        appliedContentModes.append(contentMode)
    }

    func reveal() {
        revealCount += 1
    }

    func reassertDesktopPlacement() {
        reassertCount += 1
    }

    func close() {
        closeCount += 1
    }
}

@MainActor
final class TestDesktopStatusPresenter: DesktopStatusPresenting {
    var stateProvider: (() -> DesktopStatusState)?
    var togglePlaybackHandler: (() -> Void)?
    var playNextHandler: (() -> Void)?
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)?
    var returnToPlayerHandler: (() -> Void)?
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)?
    var quitHandler: (() -> Void)?
    private(set) var showCount = 0
    private(set) var removeCount = 0

    func show() {
        showCount += 1
    }

    func remove() {
        removeCount += 1
    }
}

@MainActor
final class TestApplicationPresenceController: ApplicationPresenceControlling {
    private(set) var appliedModes: [ApplicationPresenceMode] = []
    var results: [Bool]

    init(results: [Bool] = []) {
        self.results = results
    }

    @discardableResult
    func setMode(_ mode: ApplicationPresenceMode) -> Bool {
        appliedModes.append(mode)
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
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ reason: PlaybackSuspensionReason, suspended: Bool) {
        suspensionHandler?(reason, suspended)
    }
}

@MainActor
final class TestMainWindowPresenter: MainWindowPresenting {
    private(set) var hideCount = 0
    private(set) var prepareForReturnCount = 0
    private(set) var showCount = 0
    private(set) var hideAfterFailedReturnCount = 0
    private(set) var dismissCount = 0
    private(set) var minimizeCount = 0
    private(set) var toggleFullScreenCount = 0

    func hide() {
        hideCount += 1
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
