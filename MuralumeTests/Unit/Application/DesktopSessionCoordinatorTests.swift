import AppKit
import XCTest
@testable import Muralume

@MainActor
final class DesktopSessionCoordinatorTests: XCTestCase {
    private enum DesktopEntryEvent: Equatable {
        case showStatusMenu
        case revealDesktop
        case setApplicationPresence(ApplicationPresenceMode)
        case hideMainWindow
    }

    private enum TestPolicy {
        static let statePropagationAttempts = 100
        static let currentMenuTitleMaximumWidth: CGFloat = 360
    }

    private enum TestStorage {
        static let suiteName = "com.muralume.tests.desktop-content-mode"
        static let contentModeKey = "desktop.video-content-mode"
    }

    func testDesktopRoundTripDelegatesWindowAndStatusPresentation() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let contentModeStore = TestDesktopVideoContentModeStore(
            contentMode: .contain
        )
        let lifecycleMonitor = TestSystemLifecycleMonitor()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: contentModeStore,
            lifecycleMonitor: lifecycleMonitor,
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        var playNextCount = 0
        var selectedPlaybackOrders: [PlaybackOrder] = []
        session.canPlayNextProvider = {
            true
        }
        session.playNextHandler = {
            playNextCount += 1
        }
        session.playbackOrderProvider = {
            .ordered
        }
        session.canSetPlaybackOrderProvider = {
            true
        }
        session.playbackOrderChangeHandler = {
            selectedPlaybackOrders.append($0)
        }
        defer {
            session.shutdown()
        }

        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        session.enterDesktop()
        await waitUntil { session.isActive }

        XCTAssertEqual(playback.presentation, .desktop)
        XCTAssertEqual(desktopHost.prepareCount, 1)
        XCTAssertEqual(desktopHost.preparedContentModes, [.contain])
        XCTAssertEqual(desktopHost.revealCount, 1)
        XCTAssertEqual(mainWindow.hideCount, 1)
        XCTAssertEqual(statusMenu.showCount, 1)
        XCTAssertEqual(applicationPresence.appliedModes, [.menuBarOnly])
        XCTAssertTrue(statusMenu.stateProvider?().canPlayNext == true)
        XCTAssertEqual(statusMenu.stateProvider?().playbackOrder, .ordered)
        XCTAssertTrue(
            statusMenu.stateProvider?().canSetPlaybackOrder == true
        )

        statusMenu.playNextHandler?()
        XCTAssertEqual(playNextCount, 1)
        statusMenu.setPlaybackOrderHandler?(.shuffled)
        XCTAssertEqual(selectedPlaybackOrders, [.shuffled])

        session.returnToPlayer()
        await waitUntil { !session.isActive && playback.presentation == .player }

        XCTAssertEqual(mainWindow.prepareForReturnCount, 1)
        XCTAssertEqual(mainWindow.showCount, 1)
        XCTAssertEqual(desktopHost.closeCount, 1)
        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(
            applicationPresence.appliedModes,
            [.menuBarOnly, .standard]
        )

        statusMenu.playNextHandler?()
        XCTAssertEqual(playNextCount, 1)
        statusMenu.setPlaybackOrderHandler?(.ordered)
        XCTAssertEqual(selectedPlaybackOrders, [.shuffled])
    }

    func testStatusMenuFailureRestoresPlayerBeforeHidingApplication() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        statusMenu.showResult = false
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        var didEnterDesktopCount = 0
        session.didEnterDesktopHandler = {
            didEnterDesktopCount += 1
        }
        defer {
            session.shutdown()
        }

        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        let didEnterDesktop = await session.enterDesktopAndWait()

        XCTAssertFalse(didEnterDesktop)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(playback.presentation, .player)
        XCTAssertEqual(session.transientFailure, .statusMenuUnavailable)
        XCTAssertEqual(statusMenu.showCount, 1)
        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(desktopHost.revealCount, 0)
        XCTAssertEqual(desktopHost.closeCount, 1)
        XCTAssertEqual(mainWindow.hideCount, 0)
        XCTAssertEqual(mainWindow.showCount, 1)
        XCTAssertEqual(applicationPresence.appliedModes, [.standard])
        XCTAssertEqual(didEnterDesktopCount, 0)
    }

    func testDesktopEntryEstablishesStatusMenuBeforeHidingApplication() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }
        var events: [DesktopEntryEvent] = []
        statusMenu.showHandler = {
            events.append(.showStatusMenu)
        }
        desktopHost.revealHandler = {
            events.append(.revealDesktop)
        }
        applicationPresence.setModeHandler = {
            events.append(.setApplicationPresence($0))
        }
        mainWindow.hideHandler = {
            events.append(.hideMainWindow)
        }

        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        let didEnterDesktop = await session.enterDesktopAndWait()

        XCTAssertTrue(didEnterDesktop)
        XCTAssertEqual(
            events,
            [
                .showStatusMenu,
                .revealDesktop,
                .setApplicationPresence(.menuBarOnly),
                .hideMainWindow
            ]
        )
    }

    func testCancellingDesktopEntryPreservesPlaybackIntent() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }

        playback.registerPlayerSurface(playerSurface)
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        engine.shouldBlockAttachments = true

        session.enterDesktop()
        await waitUntil {
            engine.didBeginBlockedAttachment
                && self.isSwitching(
                    playback.presentation,
                    to: .desktop
                )
        }

        engine.shouldBlockAttachments = false
        session.returnToPlayer()
        await waitUntil {
            !session.isTransitioning
                && playback.presentation == .player
        }

        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(playback.isPlayerWindowDismissed)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(mainWindow.prepareForReturnCount, 1)
        XCTAssertEqual(mainWindow.showCount, 1)
        XCTAssertEqual(desktopHost.closeCount, 1)
        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(applicationPresence.appliedModes, [.standard])
    }

    func testRepeatedReturnDuringPlayerTransitionIsNonDestructive() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: TestDesktopHost(),
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        defer {
            session.shutdown()
        }

        playback.registerPlayerSurface(playerSurface)
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        session.enterDesktop()
        await waitUntil { session.isActive }

        engine.shouldBlockAttachments = true
        session.returnToPlayer()
        await waitUntil {
            self.isSwitching(
                playback.presentation,
                to: .player
            )
        }

        session.returnToPlayer()

        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertFalse(playback.isPlayerWindowDismissed)
        XCTAssertTrue(
            isSwitching(playback.presentation, to: .player)
        )
    }

    func testLifecycleEventsPauseOnlyTheDesktopPresentation() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let lifecycleMonitor = TestSystemLifecycleMonitor()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: TestDesktopHost(),
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: lifecycleMonitor,
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        defer {
            session.shutdown()
        }

        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        XCTAssertTrue(engine.isPlaying)

        lifecycleMonitor.emit(.screenLocked, suspended: true)
        XCTAssertTrue(engine.isPlaying)

        session.enterDesktop()
        await waitUntil { session.isActive }
        XCTAssertFalse(engine.isPlaying)

        lifecycleMonitor.emit(.screenLocked, suspended: false)
        XCTAssertTrue(engine.isPlaying)
    }

    func testDismissMainWindowPausesWithoutDiscardingPlayerState() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await playback.load(source)

        session.dismissMainWindow()

        XCTAssertEqual(mainWindow.dismissCount, 1)
        XCTAssertEqual(playback.source, source)
        XCTAssertEqual(playback.readiness, .ready)
        XCTAssertTrue(playback.isPlayerWindowDismissed)
        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(applicationPresence.appliedModes.isEmpty)
        XCTAssertEqual(desktopHost.closeCount, 0)
        XCTAssertEqual(statusMenu.removeCount, 0)
    }

    func testDismissMainWindowLeavesDesktopModeWithoutShowingPlayer() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await playback.load(source)
        session.enterDesktop()
        await waitUntil { session.isActive }

        session.dismissMainWindow()

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(playback.presentation, .player)
        XCTAssertEqual(playback.source, source)
        XCTAssertTrue(playback.isPlayerWindowDismissed)
        XCTAssertEqual(mainWindow.dismissCount, 1)
        XCTAssertEqual(mainWindow.showCount, 0)
        XCTAssertEqual(desktopHost.closeCount, 1)
        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(
            applicationPresence.appliedModes,
            [.menuBarOnly, .standard]
        )
    }

    func testChangingVideoContentModeUpdatesActiveDesktopAndPersistence() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let contentModeStore = TestDesktopVideoContentModeStore()
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: contentModeStore,
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        defer {
            session.shutdown()
        }

        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        session.enterDesktop()
        await waitUntil { session.isActive }

        statusMenu.setVideoContentModeHandler?(.contain)

        XCTAssertEqual(session.videoContentMode, .contain)
        XCTAssertEqual(contentModeStore.savedContentModes, [.contain])
        XCTAssertEqual(desktopHost.appliedContentModes, [.contain])
        XCTAssertEqual(statusMenu.stateProvider?().videoContentMode, .contain)

        statusMenu.setVideoContentModeHandler?(.contain)
        XCTAssertEqual(contentModeStore.savedContentModes, [.contain])
        XCTAssertEqual(desktopHost.appliedContentModes, [.contain])
    }

    func testFailedMenuBarOnlyTransitionRestoresPlayerAndStatusEntry() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController(
            results: [false, true]
        )
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }

        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        session.enterDesktop()
        await waitUntil {
            session.transientFailure == .playback(.surfaceTimeout)
                && playback.presentation == .player
        }

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(statusMenu.showCount, 1)
        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(desktopHost.closeCount, 1)
        XCTAssertEqual(mainWindow.showCount, 1)
        XCTAssertEqual(
            applicationPresence.appliedModes,
            [.menuBarOnly, .standard]
        )
    }

    func testWaitedDesktopEntryDoesNotReportRecoveryLimboAsSuccess() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let applicationPresence = TestApplicationPresenceController(
            results: [false, false]
        )
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: TestDesktopHost(),
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }
        playback.registerPlayerSurface(playerSurface)
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        let didEnterDesktop = await session.enterDesktopAndWait()

        XCTAssertFalse(didEnterDesktop)
        XCTAssertEqual(playback.presentation, .player)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(
            session.transientFailure,
            .playback(.surfaceTimeout)
        )
    }

    func testFailedStandardPresenceKeepsStatusEntryUntilRetry() async {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let mainWindow = TestMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController(
            results: [true, false, true]
        )
        let session = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: mainWindow,
            applicationPresence: applicationPresence
        )
        defer {
            session.shutdown()
        }

        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        await Task.yield()
        await playback.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        session.enterDesktop()
        await waitUntil { session.isActive }

        session.returnToPlayer()

        XCTAssertTrue(session.isActive)
        XCTAssertEqual(playback.presentation, .desktop)
        XCTAssertEqual(statusMenu.removeCount, 0)
        XCTAssertEqual(mainWindow.prepareForReturnCount, 0)
        XCTAssertEqual(
            session.transientFailure,
            .playback(.surfaceTimeout)
        )

        session.returnToPlayer()
        await waitUntil {
            !session.isActive && playback.presentation == .player
        }

        XCTAssertEqual(statusMenu.removeCount, 1)
        XCTAssertEqual(mainWindow.prepareForReturnCount, 1)
        XCTAssertNil(session.transientFailure)
        XCTAssertEqual(
            applicationPresence.appliedModes,
            [.menuBarOnly, .standard, .standard]
        )
    }

    func testUserDefaultsVideoContentModeStorePersistsSelectionAndUsesNewDefault()
        throws
    {
        let suiteName = TestStorage.suiteName
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.removePersistentDomain(forName: suiteName)

        let initialStore = UserDefaultsDesktopVideoContentModeStore(
            defaults: defaults
        )
        XCTAssertEqual(initialStore.load(), .blurredBackground)

        defaults.set("unknown-mode", forKey: TestStorage.contentModeKey)
        XCTAssertEqual(initialStore.load(), .blurredBackground)

        defaults.set(
            DesktopVideoContentMode.cover.rawValue,
            forKey: TestStorage.contentModeKey
        )
        XCTAssertEqual(initialStore.load(), .cover)

        defaults.set(
            DesktopVideoContentMode.contain.rawValue,
            forKey: TestStorage.contentModeKey
        )
        XCTAssertEqual(initialStore.load(), .contain)

        initialStore.save(.blurredBackground)

        let restoredStore = UserDefaultsDesktopVideoContentModeStore(
            defaults: defaults
        )
        XCTAssertEqual(restoredStore.load(), .blurredBackground)
    }

    func testStatusMenuUsesBrandTemplateAndExpectedDesktopActions() throws {
        let localization = AppLocalizationController(
            initialLanguage: .english
        )
        let controller = DesktopStatusMenuController(
            localization: localization
        )
        var selectedContentMode: DesktopVideoContentMode?
        var selectedPlaybackRate: PlaybackRate?
        var selectedPlaybackOrder: PlaybackOrder?
        var playNextCount = 0
        var statusState = DesktopStatusState(
            sourceName: "Example",
            isPlaying: true,
            isTransitioning: false,
            canPlayNext: true,
            playbackOrder: .ordered,
            canSetPlaybackOrder: true,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .contain
        )
        controller.stateProvider = {
            statusState
        }
        controller.playNextHandler = {
            playNextCount += 1
        }
        controller.setPlaybackOrderHandler = {
            selectedPlaybackOrder = $0
        }
        controller.setPlaybackRateHandler = {
            selectedPlaybackRate = $0
        }
        controller.setVideoContentModeHandler = {
            selectedContentMode = $0
        }

        let image = try XCTUnwrap(controller.makeMenuBarImage())
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

        let menu = controller.makeMenu()
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.count, 9)
        XCTAssertEqual(actionName(menu.items[1]), "togglePlayback")
        XCTAssertEqual(actionName(menu.items[2]), "playNext")
        XCTAssertEqual(actionName(menu.items[6]), "returnToPlayer")
        XCTAssertTrue(menu.items[7].isSeparatorItem)
        XCTAssertEqual(actionName(menu.items[8]), "quitApplication")
        XCTAssertFalse(
            menu.items.compactMap(\.action).map(NSStringFromSelector).contains {
                $0.localizedCaseInsensitiveContains("stop")
            }
        )

        menu.performActionForItem(at: 2)
        XCTAssertEqual(playNextCount, 1)

        statusState = DesktopStatusState(
            sourceName: "Example",
            isPlaying: true,
            isTransitioning: false,
            canPlayNext: false,
            playbackOrder: .ordered,
            canSetPlaybackOrder: false,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .contain
        )
        controller.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)

        statusState = DesktopStatusState(
            sourceName: "Example",
            isPlaying: true,
            isTransitioning: true,
            canPlayNext: true,
            playbackOrder: .ordered,
            canSetPlaybackOrder: true,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .contain
        )
        controller.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)
        XCTAssertFalse(menu.items[4].isEnabled)

        statusState = DesktopStatusState(
            sourceName: "Example",
            isPlaying: true,
            isTransitioning: false,
            canPlayNext: true,
            playbackOrder: .ordered,
            canSetPlaybackOrder: true,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .contain
        )
        controller.menuNeedsUpdate(menu)
        let playbackOrderItems = try XCTUnwrap(menu.items[3].submenu?.items)
        XCTAssertEqual(
            playbackOrderItems.compactMap { $0.representedObject as? String },
            [PlaybackOrder.shuffled.rawValue, PlaybackOrder.ordered.rawValue]
        )
        XCTAssertEqual(playbackOrderItems.map(\.title), ["Shuffle", "In Order"])
        XCTAssertEqual(playbackOrderItems.map(\.state), [.off, .on])

        let playbackRateItems = try XCTUnwrap(menu.items[4].submenu?.items)
        XCTAssertEqual(
            playbackRateItems.compactMap {
                ($0.representedObject as? NSNumber)?.floatValue
            },
            PlaybackPolicy.supportedRates.map(\.rawValue)
        )
        XCTAssertEqual(
            playbackRateItems.map(\.state),
            [.off, .off, .off, .off, .on, .off]
        )

        let contentModeItems = try XCTUnwrap(menu.items[5].submenu?.items)
        XCTAssertEqual(
            contentModeItems.compactMap { $0.representedObject as? String },
            [
                DesktopVideoContentMode.blurredBackground.rawValue,
                DesktopVideoContentMode.cover.rawValue,
                DesktopVideoContentMode.contain.rawValue
            ]
        )
        XCTAssertEqual(
            contentModeItems.map(\.title),
            ["Blurred Background", "Fill Screen", "Fit to Screen"]
        )
        XCTAssertEqual(contentModeItems.map(\.state), [.off, .off, .on])

        statusState = DesktopStatusState(
            sourceName: "Example",
            isPlaying: true,
            isTransitioning: false,
            canPlayNext: true,
            playbackOrder: .shuffled,
            canSetPlaybackOrder: true,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .blurredBackground
        )
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(playbackOrderItems.map(\.state), [.on, .off])
        XCTAssertEqual(contentModeItems.map(\.state), [.on, .off, .off])

        localization.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(menu.items[1].title, "暂停")
        XCTAssertEqual(menu.items[2].title, "播放下一个")
        XCTAssertEqual(menu.items[3].title, "播放顺序")
        XCTAssertEqual(menu.items[4].title, "播放速度")
        XCTAssertEqual(menu.items[5].title, "桌面适配")
        XCTAssertEqual(menu.items[6].title, "返回播放器")
        XCTAssertEqual(menu.items[8].title, "退出 Muralume")
        XCTAssertEqual(
            menu.items[3].submenu?.items.map(\.title),
            ["随机播放", "顺序播放"]
        )
        XCTAssertEqual(
            menu.items[5].submenu?.items.map(\.title),
            ["模糊背景", "填满屏幕", "完整显示"]
        )

        menu.items[3].submenu?.performActionForItem(at: 0)
        XCTAssertEqual(selectedPlaybackOrder, .shuffled)

        menu.items[4].submenu?.performActionForItem(at: 5)
        XCTAssertEqual(selectedPlaybackRate, PlaybackRate(rawValue: 2))

        menu.items[5].submenu?.performActionForItem(at: 0)
        XCTAssertEqual(selectedContentMode, .blurredBackground)
    }

    func testStatusMenuShowCreatesUsableIdempotentEntry() {
        let controller = DesktopStatusMenuController(
            localization: AppLocalizationController(
                initialLanguage: .english
            )
        )
        defer {
            controller.remove()
        }

        XCTAssertTrue(controller.show())
        XCTAssertTrue(controller.show())
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<TestPolicy.statePropagationAttempts {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the expected coordinator state")
    }

    func testStatusMenuMiddleTruncatesLongCurrentSourceName() throws {
        let localization = AppLocalizationController(
            initialLanguage: .english
        )
        let controller = DesktopStatusMenuController(
            localization: localization
        )
        let sourceName = String(
            repeating: "A-Very-Long-Descriptive-Video-Name-",
            count: 20
        ) + "final-cut.mp4"
        controller.stateProvider = {
            DesktopStatusState(
                sourceName: sourceName,
                isPlaying: true,
                isTransitioning: false,
                canPlayNext: false,
                playbackOrder: .ordered,
                canSetPlaybackOrder: false,
                playbackRate: PlaybackRate(rawValue: 1),
                videoContentMode: .cover
            )
        }

        let menu = controller.makeMenu()
        controller.menuNeedsUpdate(menu)
        let currentItem = try XCTUnwrap(menu.items.first)
        let fullEnglishTitle = "Now Playing: \(sourceName)"

        XCTAssertTrue(currentItem.title.hasPrefix("Now Playing: "))
        XCTAssertTrue(currentItem.title.contains("…"))
        XCTAssertTrue(currentItem.title.hasSuffix("final-cut.mp4"))
        XCTAssertNotEqual(currentItem.title, fullEnglishTitle)
        XCTAssertEqual(currentItem.toolTip, fullEnglishTitle)
        XCTAssertLessThanOrEqual(
            menuTitleWidth(currentItem.title),
            TestPolicy.currentMenuTitleMaximumWidth
        )

        localization.selectLanguage(.simplifiedChinese)

        XCTAssertTrue(currentItem.title.hasPrefix("正在播放："))
        XCTAssertTrue(currentItem.title.contains("…"))
        XCTAssertTrue(currentItem.title.hasSuffix("final-cut.mp4"))
        XCTAssertEqual(currentItem.toolTip, "正在播放：\(sourceName)")
        XCTAssertLessThanOrEqual(
            menuTitleWidth(currentItem.title),
            TestPolicy.currentMenuTitleMaximumWidth
        )
    }

    private func menuTitleWidth(_ title: String) -> CGFloat {
        ceil(
            (title as NSString).size(
                withAttributes: [.font: NSFont.menuFont(ofSize: 0)]
            ).width
        )
    }

    private func actionName(_ item: NSMenuItem) -> String? {
        item.action.map(NSStringFromSelector)
    }

    private func isSwitching(
        _ presentation: PlaybackPresentation,
        to destination: PlaybackSurfaceID
    ) -> Bool {
        guard case let .switching(_, currentDestination) = presentation else {
            return false
        }
        return currentDestination == destination
    }
}
