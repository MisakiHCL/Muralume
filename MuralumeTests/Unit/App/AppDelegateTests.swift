import AppKit
import Combine
import XCTest
@testable import Muralume

@MainActor
final class AppDelegateTests: XCTestCase {
    func testLastWindowClosingDoesNotTerminateApplication() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp)
        )
    }

    func testReopenAlwaysRoutesToCoordinatorAndSuppressesDefaultHandling() {
        let delegate = AppDelegate()
        let coordinator = TestAppLifecycleCoordinator()
        delegate.coordinator = coordinator

        let handledWithNoVisibleWindows =
            delegate.applicationShouldHandleReopen(
                NSApp,
                hasVisibleWindows: false
            )
        let handledWithVisibleAuxiliaryWindow =
            delegate.applicationShouldHandleReopen(
                NSApp,
                hasVisibleWindows: true
            )

        XCTAssertFalse(handledWithNoVisibleWindows)
        XCTAssertFalse(handledWithVisibleAuxiliaryWindow)
        XCTAssertEqual(coordinator.reopenMainWindowCount, 2)
    }

    func testReopenWithoutCoordinatorFallsBackToDefaultHandling() {
        let delegate = AppDelegate()

        let handled = delegate.applicationShouldHandleReopen(
            NSApp,
            hasVisibleWindows: true
        )

        XCTAssertTrue(handled)
    }

    func testActivationRestoresMainWindowOnlyWhenNoWindowIsVisible() {
        let delegate = AppDelegate()
        let coordinator = TestAppLifecycleCoordinator()
        delegate.coordinator = coordinator

        delegate.restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: true
        )
        XCTAssertEqual(coordinator.reopenMainWindowCount, 0)

        delegate.restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: false
        )
        XCTAssertEqual(coordinator.reopenMainWindowCount, 1)
    }

    func testMainMenuControllerBuildsOnlyCanonicalTopLevelMenus() {
        let commandHandler = TestMainMenuCommandHandler()
        let window = NSWindow()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: window
        )

        XCTAssertEqual(
            controller.canonicalMenu.items.map(\.title),
            ["Muralume", "Actions", "Window", "Help"]
        )
        XCTAssertFalse(
            controller.canonicalMenu.items.contains {
                ["File", "Edit", "Format", "View"].contains($0.title)
            }
        )
    }

    func testRuntimeMainWindowIsExcludedFromAutomaticWindowMenu() {
        let window = MacApplicationRuntime.makeMainWindow(
            title: "Muralume"
        )

        XCTAssertTrue(window.isExcludedFromWindowsMenu)
    }

    func testRuntimeMainWindowRoutesCancelOperationToPanelHandler() {
        let window = MacApplicationRuntime.makeMainWindow(
            title: "Muralume"
        )
        var invocationCount = 0
        window.cancelOperationHandler = {
            invocationCount += 1
            return true
        }

        window.cancelOperation(nil)

        XCTAssertEqual(invocationCount, 1)
    }

    func testCanonicalApplicationMenuKeepsStandardMacActions() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let applicationMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first?.submenu
        )

        XCTAssertEqual(
            applicationMenu.items
                .filter { !$0.isSeparatorItem }
                .map(\.title),
            [
                "About Muralume",
                "Settings…",
                "Services",
                "Hide Muralume",
                "Hide Others",
                "Show All",
                "Quit Muralume"
            ]
        )
        XCTAssertNotNil(
            applicationMenu.items.first {
                $0.title == "Services"
            }?.submenu
        )
        XCTAssertEqual(
            applicationMenu.items.first {
                $0.title == "Settings…"
            }?.keyEquivalent,
            ","
        )
        XCTAssertEqual(
            applicationMenu.items.first {
                $0.title == "Quit Muralume"
            }?.keyEquivalent,
            "q"
        )
    }

    func testPlayerMenuUsesOneShortcutOwnerAndDynamicState() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )

        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Add Folder"
            }?.keyEquivalent,
            "o"
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Play"
            }?.keyEquivalent,
            " "
        )
        XCTAssertEqual(
            actionsMenu.items.first {
                $0.title == "Toggle Full Screen"
            }?.keyEquivalent,
            "f"
        )

        let activeState = MacMainMenuCommandState(
            isPlaybackRequested: true,
            isMuted: true,
            canControlPlayback: true,
            canPlayPrevious: true,
            canPlayNext: true,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canUseWindowActions: true
        )
        controller.refreshPlayerCommands(
            state: activeState,
            hasPlayerFocus: true
        )

        XCTAssertTrue(
            actionsMenu.items
                .filter { !$0.isSeparatorItem }
                .allSatisfy(\.isEnabled)
        )
        XCTAssertNotNil(
            actionsMenu.items.first { $0.title == "Pause" }
        )
        XCTAssertNotNil(
            actionsMenu.items.first { $0.title == "Unmute" }
        )

        controller.refreshPlayerCommands(
            state: activeState,
            hasPlayerFocus: false
        )
        XCTAssertTrue(
            actionsMenu.items
                .filter { !$0.isSeparatorItem }
                .allSatisfy { !$0.isEnabled }
        )
    }

    func testPlayerMenuKeepsGlobalAudioCommandsEnabledWithoutMedia() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )
        let emptyMediaState = MacMainMenuCommandState(
            isPlaybackRequested: false,
            isMuted: false,
            canControlPlayback: false,
            canPlayPrevious: false,
            canPlayNext: false,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canUseWindowActions: true
        )

        controller.refreshPlayerCommands(
            state: emptyMediaState,
            hasPlayerFocus: true
        )

        for title in [
            "Add Folder",
            "Volume Up",
            "Volume Down",
            "Mute",
            "Toggle Full Screen"
        ] {
            XCTAssertEqual(
                actionsMenu.items.first { $0.title == title }?.isEnabled,
                true,
                "\(title) should remain available without media"
            )
        }
        for title in [
            "Play",
            "Back 10 seconds",
            "Forward 10 seconds",
            "Previous Video",
            "Next Video"
        ] {
            XCTAssertEqual(
                actionsMenu.items.first { $0.title == title }?.isEnabled,
                false,
                "\(title) should require playable media"
            )
        }
    }

    func testPlayerMenuActionRevalidatesWindowFocusBeforeDispatch() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(
            commandHandler: commandHandler,
            mainWindow: NSWindow()
        )
        let actionsMenu = try XCTUnwrap(
            controller.canonicalMenu.items.first {
                $0.title == "Actions"
            }?.submenu
        )
        let staleEnabledState = MacMainMenuCommandState(
            isPlaybackRequested: true,
            isMuted: false,
            canControlPlayback: true,
            canPlayPrevious: true,
            canPlayNext: true,
            canIncreaseVolume: true,
            canDecreaseVolume: true,
            canUseWindowActions: true
        )
        controller.refreshPlayerCommands(
            state: staleEnabledState,
            hasPlayerFocus: true
        )
        let pauseItem = try XCTUnwrap(
            actionsMenu.items.first { $0.title == "Pause" }
        )
        let action = try XCTUnwrap(pauseItem.action)

        XCTAssertTrue(pauseItem.isEnabled)
        XCTAssertTrue(
            NSApp.sendAction(
                action,
                to: pauseItem.target,
                from: pauseItem
            )
        )
        XCTAssertEqual(commandHandler.togglePlaybackCommandCount, 0)
        XCTAssertFalse(pauseItem.isEnabled)
    }

    private func makeMainMenuController(
        commandHandler: TestMainMenuCommandHandler,
        mainWindow: NSWindow
    ) -> MacMainMenuController {
        MacMainMenuController(
            application: NSApp,
            localization: AppLocalizationController(
                initialLanguage: .english
            ),
            commandHandler: commandHandler,
            mainWindow: mainWindow
        )
    }
}

@MainActor
private final class TestAppLifecycleCoordinator:
    AppLifecycleCoordinating
{
    private(set) var reopenMainWindowCount = 0

    func reopenMainWindow() {
        reopenMainWindowCount += 1
    }

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        false
    }

    func shutdown() async {}
}

@MainActor
private final class TestMainMenuCommandHandler:
    MacMainMenuCommandHandling
{
    private let stateDidChange = PassthroughSubject<Void, Never>()
    private(set) var togglePlaybackCommandCount = 0

    var mainMenuCommandState = MacMainMenuCommandState(
        isPlaybackRequested: false,
        isMuted: false,
        canControlPlayback: false,
        canPlayPrevious: false,
        canPlayNext: false,
        canIncreaseVolume: false,
        canDecreaseVolume: false,
        canUseWindowActions: true
    )

    var mainMenuCommandStateDidChange: AnyPublisher<Void, Never> {
        stateDidChange.eraseToAnyPublisher()
    }

    func openSettings() {}
    func addFolders() {}
    func togglePlaybackFromMenu() {
        togglePlaybackCommandCount += 1
    }
    func seekBackwardFromMenu() {}
    func seekForwardFromMenu() {}
    func playPreviousFromMenu() {}
    func playNextFromMenu() {}
    func increaseVolumeFromMenu() {}
    func decreaseVolumeFromMenu() {}
    func toggleMuteFromMenu() {}
    func toggleFullScreen() {}

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        false
    }
}
