import AppKit
import XCTest
@testable import Muralume

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private enum TestPolicy {
        static let propagationAttempts = 1_000
    }

    func testInteractiveLaunchDoesNotRestoreEvenWhenLoginItemIsEffective() async {
        let fixture = makeFixture(launchStatus: .enabled)

        fixture.coordinator.start(source: .interactive)
        await Task.yield()
        let loadCount = await fixture.store.loadCount

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(fixture.applicationPresence.appliedModes, [.standard])

        await fixture.coordinator.shutdown()
    }

    func testLoginLaunchFallsBackToPlayerWhenApprovalIsNotEffective() async {
        let fixture = makeFixture(launchStatus: .requiresApproval)

        fixture.coordinator.start(source: .loginItem)
        await Task.yield()
        let loadCount = await fixture.store.loadCount

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(fixture.applicationPresence.appliedModes, [.standard])

        await fixture.coordinator.shutdown()
    }

    func testEffectiveLoginLaunchStartsRestoreWithoutShowingPlayer() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockPresetLoad: true
        )

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            await fixture.store.didBeginBlockedLoad
        }

        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertTrue(fixture.applicationPresence.appliedModes.isEmpty)

        await fixture.store.finishBlockedLoad()
        await fixture.coordinator.shutdown()
    }

    func testDockReopenCancelsInFlightBootstrapWithoutLateHide() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockDesktopAttachment: true
        )

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.engine.didBeginBlockedDesktopAttachment
        }

        fixture.coordinator.reopenMainWindow()
        await waitUntil {
            fixture.window.isVisible
                && fixture.playback.presentation == .player
                && !fixture.desktopSession.isTransitioning
        }

        fixture.engine.finishBlockedDesktopAttachment()
        await waitUntil {
            fixture.desktopPreset.bootstrapState == .cancelled
        }
        await Task.yield()

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(fixture.applicationPresence.appliedModes.last, .standard)

        await fixture.coordinator.shutdown()
    }

    func testShutdownCancelsAndDrainsBootstrapBeforeFinalTeardown() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockDesktopAttachment: true
        )
        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.engine.didBeginBlockedDesktopAttachment
        }

        let shutdownTask = Task {
            await fixture.coordinator.shutdown()
        }
        await waitUntil {
            fixture.engine.stopCount == 1
        }

        XCTAssertEqual(fixture.thumbnailProvider.shutdownCount, 0)
        XCTAssertEqual(fixture.mediaSession.stopCount, 0)

        fixture.engine.finishBlockedDesktopAttachment()
        await shutdownTask.value

        XCTAssertEqual(fixture.thumbnailProvider.shutdownCount, 1)
        XCTAssertEqual(fixture.mediaSession.stopCount, 1)
        let persistenceCounts = await fixture.store.persistenceCounts

        fixture.engine.emitProgress(99)
        await Task.yield()
        await Task.yield()
        let finalPersistenceCounts = await fixture.store.persistenceCounts

        XCTAssertEqual(finalPersistenceCounts, persistenceCounts)
    }

    func testMenuDesktopActionRestoresSoftClosedPlayerBeforeTransition() async {
        let fixture = makeFixture(launchStatus: .disabled)
        fixture.coordinator.start(source: .interactive)
        await prepareActiveQueue(in: fixture)

        fixture.coordinator.dismissMainWindow()

        XCTAssertTrue(fixture.playback.isPlayerWindowDismissed)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertTrue(fixture.coordinator.mainMenuCommandState.canEnterDesktop)

        fixture.coordinator.enterDesktopFromMenu()
        await waitUntil {
            fixture.desktopSession.isActive
                && fixture.playback.presentation == .desktop
        }

        XCTAssertFalse(fixture.playback.isPlayerWindowDismissed)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(fixture.desktopHost.revealCount, 1)
        XCTAssertEqual(fixture.applicationPresence.appliedModes.last, .menuBarOnly)

        await fixture.coordinator.shutdown()
    }

    private func prepareActiveQueue(in fixture: AppCoordinatorFixture) async {
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(fixture.item)
        await waitUntil {
            fixture.playback.readiness == .ready
        }
    }

    private func makeFixture(
        launchStatus: LaunchAtLoginStatus,
        blockPresetLoad: Bool = false,
        blockDesktopAttachment: Bool = false
    ) -> AppCoordinatorFixture {
        let rootURL = URL(
            fileURLWithPath: "/tmp/AppCoordinatorTests/Library"
        )
        let item = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent("clip.mp4"),
            displayName: "Clip",
            relativePath: "clip.mp4",
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
        let queue = PlaybackQueue(items: [item.id])
        let preset = DesktopPreset(
            queue: queue.makeSnapshot()!,
            currentTime: 12,
            isPlaybackRequested: true,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .cover
        )
        let engine = AppCoordinatorPlaybackEngine(
            blocksDesktopAttachment: blockDesktopAttachment
        )
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        let mediaSession = AppCoordinatorMediaSession(rootURL: rootURL)
        let library = MediaLibraryCoordinator(
            playback: playback,
            folderSelector: AppCoordinatorFolderSelector(),
            mediaSession: mediaSession,
            scanner: AppCoordinatorMediaScanner(
                snapshot: MediaLibrarySnapshot(
                    roots: [
                        MediaLibraryRoot(
                            url: rootURL,
                            displayName: "Library"
                        )
                    ],
                    items: [item]
                )
            ),
            playbackOrder: .ordered
        )
        let windowPresenter = MacMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let desktopHost = TestDesktopHost()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: windowPresenter,
            applicationPresence: applicationPresence
        )
        let store = AppCoordinatorPresetStore(
            preset: preset,
            blocksLoad: blockPresetLoad
        )
        let desktopPreset = DesktopPresetController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: store
        )
        let launchService = AppCoordinatorLaunchAtLoginService(
            status: launchStatus
        )
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: launchService),
            desktopPreset: desktopPreset
        )
        let thumbnailProvider = AppCoordinatorThumbnailProvider()
        let coordinator = AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            mediaThumbnailProvider: thumbnailProvider,
            mainWindowPresenter: windowPresenter,
            applicationPresence: applicationPresence,
            dynamicDesktopStartup: startup,
            desktopPreset: desktopPreset
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        coordinator.attachMainWindow(window)

        return AppCoordinatorFixture(
            coordinator: coordinator,
            playback: playback,
            desktopSession: desktopSession,
            desktopPreset: desktopPreset,
            library: library,
            desktopHost: desktopHost,
            applicationPresence: applicationPresence,
            thumbnailProvider: thumbnailProvider,
            mediaSession: mediaSession,
            store: store,
            engine: engine,
            playerSurface: playerSurface,
            item: item,
            window: window
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<TestPolicy.propagationAttempts {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for coordinator state propagation")
    }
}

@MainActor
private struct AppCoordinatorFixture {
    let coordinator: AppCoordinator
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let desktopPreset: DesktopPresetController
    let library: MediaLibraryCoordinator
    let desktopHost: TestDesktopHost
    let applicationPresence: TestApplicationPresenceController
    let thumbnailProvider: AppCoordinatorThumbnailProvider
    let mediaSession: AppCoordinatorMediaSession
    let store: AppCoordinatorPresetStore
    let engine: AppCoordinatorPlaybackEngine
    let playerSurface: TestPlaybackSurface
    let item: LibraryMediaItem
    let window: NSWindow
}

@MainActor
private final class AppCoordinatorPlaybackEngine: PlaybackEngine {
    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?

    private(set) var didBeginBlockedDesktopAttachment = false
    private(set) var stopCount = 0
    private var blocksDesktopAttachment: Bool
    private var desktopAttachmentContinuation:
        CheckedContinuation<Void, any Error>?

    init(blocksDesktopAttachment: Bool) {
        self.blocksDesktopAttachment = blocksDesktopAttachment
    }

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        120
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        guard surface.id == .desktop, blocksDesktopAttachment else {
            return
        }
        didBeginBlockedDesktopAttachment = true
        try await withCheckedThrowingContinuation { continuation in
            desktopAttachmentContinuation = continuation
        }
    }

    func finishBlockedDesktopAttachment() {
        blocksDesktopAttachment = false
        desktopAttachmentContinuation?.resume()
        desktopAttachmentContinuation = nil
    }

    func detachAll() {}

    func play(at rate: PlaybackRate) {
        playbackActivityHandler?(true)
    }

    func pause() {
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {}

    func setVolume(_ volume: PlaybackVolume) {}

    func setMuted(_ isMuted: Bool) {}

    func stop() {
        stopCount += 1
        playbackActivityHandler?(false)
    }

    func emitProgress(_ seconds: TimeInterval) {
        progressHandler?(seconds)
    }
}

@MainActor
private final class AppCoordinatorFolderSelector: MediaFolderSelecting {
    func selectFolders() -> [URL] {
        []
    }
}

@MainActor
private final class AppCoordinatorMediaSession: MediaAccessSession {
    private let rootURL: URL
    private(set) var stopCount = 0

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func restoreFolders() -> [URL] {
        [rootURL]
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        [rootURL]
    }

    func removeFolder(_ url: URL) -> [URL] {
        []
    }

    func stop() {
        stopCount += 1
    }
}

private final class AppCoordinatorMediaScanner:
    MediaLibraryScanning,
    @unchecked Sendable {
    private let snapshot: MediaLibrarySnapshot

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        snapshot
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        .available
    }
}

private actor AppCoordinatorPresetStore: DesktopPresetStoring {
    private var preset: DesktopPreset?
    private var blocksLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var clearCount = 0
    private(set) var didBeginBlockedLoad = false

    var persistenceCounts: [Int] {
        [saveCount, clearCount]
    }

    init(preset: DesktopPreset?, blocksLoad: Bool) {
        self.preset = preset
        self.blocksLoad = blocksLoad
    }

    func load() async throws -> DesktopPreset? {
        loadCount += 1
        if blocksLoad {
            didBeginBlockedLoad = true
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return preset
    }

    func finishBlockedLoad() {
        blocksLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func save(_ preset: DesktopPreset) async throws {
        saveCount += 1
        self.preset = preset
    }

    func clear() async throws {
        clearCount += 1
        preset = nil
    }
}

@MainActor
private final class AppCoordinatorLaunchAtLoginService:
    LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() {
        status = .enabled
    }

    func unregister() {
        status = .disabled
    }

    func openSystemSettings() {}
}

@MainActor
private final class AppCoordinatorThumbnailProvider: MediaThumbnailProviding {
    private(set) var shutdownCount = 0

    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        nil
    }

    func shutdown() async {
        shutdownCount += 1
    }
}
