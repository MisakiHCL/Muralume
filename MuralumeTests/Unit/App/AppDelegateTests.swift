import AppKit
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

    func testMainMenuControllerRemovesOnlyRedundantStandardMenus() {
        let mainMenu = NSMenu()
        addTopLevelMenu(
            title: "Muralume",
            action: #selector(NSApplication.hide(_:)),
            to: mainMenu
        )
        addTopLevelMenu(
            title: "File",
            action: #selector(NSWindow.performClose(_:)),
            to: mainMenu
        )
        addTopLevelMenu(
            title: "Edit",
            action: Selector(("undo:")),
            to: mainMenu
        )
        addTopLevelMenu(
            title: "Format",
            action: Selector(("showFonts:")),
            to: mainMenu
        )
        addTopLevelMenu(
            title: "View",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            to: mainMenu
        )
        addTopLevelMenu(
            title: "Actions",
            action: Selector(("menuAction:")),
            to: mainMenu
        )
        let windowsMenu = addTopLevelMenu(
            title: "Window",
            action: #selector(NSWindow.performMiniaturize(_:)),
            to: mainMenu
        )
        windowsMenu.addItem(
            NSMenuItem(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )
        windowsMenu.addItem(
            NSMenuItem(
                title: "Toggle Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f"
            )
        )
        addTopLevelMenu(
            title: "Help",
            action: #selector(NSApplication.showHelp(_:)),
            to: mainMenu
        )

        MacMainMenuController().removeRedundantTopLevelMenus(
            from: mainMenu,
            windowsMenu: windowsMenu
        )

        XCTAssertEqual(
            mainMenu.items.map(\.title),
            ["Muralume", "Actions", "Window", "Help"]
        )
    }

    @discardableResult
    private func addTopLevelMenu(
        title: String,
        action: Selector,
        to mainMenu: NSMenu
    ) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.addItem(
            NSMenuItem(title: title, action: action, keyEquivalent: "")
        )
        let topLevelItem = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        topLevelItem.submenu = submenu
        mainMenu.addItem(topLevelItem)
        return submenu
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
