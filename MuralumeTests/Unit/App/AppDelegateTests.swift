import AppKit
import XCTest
@testable import Muralume

@MainActor
final class AppDelegateTests: XCTestCase {
    func testReopenRoutesDesktopSessionEvenWhenHostWindowIsVisible() {
        let delegate = AppDelegate()
        let coordinator = TestAppLifecycleCoordinator(
            shouldRouteReopenToDesktopSession: true
        )
        delegate.coordinator = coordinator

        let handled = delegate.applicationShouldHandleReopen(
            NSApp,
            hasVisibleWindows: true
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(coordinator.returnToPlayerCount, 1)
        XCTAssertEqual(coordinator.showMainWindowCount, 0)
    }
}

@MainActor
private final class TestAppLifecycleCoordinator:
    AppLifecycleCoordinating
{
    let shouldRouteReopenToDesktopSession: Bool
    private(set) var returnToPlayerCount = 0
    private(set) var showMainWindowCount = 0

    init(shouldRouteReopenToDesktopSession: Bool) {
        self.shouldRouteReopenToDesktopSession =
            shouldRouteReopenToDesktopSession
    }

    func returnToPlayer() {
        returnToPlayerCount += 1
    }

    func showMainWindow() {
        showMainWindowCount += 1
    }

    func shutdown() async {}
}
