import AppKit
import XCTest
@testable import Muralume

@MainActor
final class MacMainWindowPresenterTests: XCTestCase {
    func testAttachUsesIntegratedFullSizeTitleBar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(
            identifier: "MacMainWindowPresenterTests.Toolbar"
        )
        let presenter = MacMainWindowPresenter()

        presenter.attach(window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertNil(window.toolbar)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertEqual(
            window.contentView?.frame.size,
            window.frame.size
        )
        XCTAssertEqual(
            window.minSize,
            NSSize(
                width: AppConfiguration.minimumWindowWidth,
                height: AppConfiguration.minimumWindowHeight
            )
        )
    }

    func testAttachHidesSystemWindowControls() {
        let window = makeWindow()
        let presenter = MacMainWindowPresenter()

        presenter.attach(window)

        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertTrue(buttons.allSatisfy(\.isHidden))
    }

    func testClosePerformsTheBoundWindowCloseAction() {
        let window = makeWindow()
        window.isReleasedWhenClosed = false
        let presenter = MacMainWindowPresenter()
        var closeCount = 0
        presenter.mainWindowCloseHandler = {
            closeCount += 1
        }
        presenter.attach(window)
        window.orderFront(nil)

        presenter.close()

        XCTAssertEqual(closeCount, 1)
    }

    func testMinimizeMiniaturizesTheBoundWindow() async {
        let window = makeWindow()
        window.isReleasedWhenClosed = false
        let presenter = MacMainWindowPresenter()
        presenter.attach(window)
        window.orderFront(nil)
        let didMiniaturize = expectation(
            forNotification: NSWindow.didMiniaturizeNotification,
            object: window
        )

        presenter.minimize()

        await fulfillment(of: [didMiniaturize], timeout: 2)
        XCTAssertTrue(window.isMiniaturized)
        window.deminiaturize(nil)
        window.orderOut(nil)
    }

    func testAttachedMainWindowCloseIsObservedOnce() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let presenter = MacMainWindowPresenter()
        var closeCount = 0
        presenter.mainWindowCloseHandler = {
            closeCount += 1
        }

        presenter.attach(window)
        presenter.attach(window)
        window.orderOut(nil)

        XCTAssertEqual(closeCount, 0)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        XCTAssertEqual(closeCount, 1)
    }

    func testPublishesOnlyAttachedMainWindowFullScreenState() {
        let attachedWindow = makeWindow()
        let unrelatedWindow = makeWindow()
        let presenter = MacMainWindowPresenter()
        var publishedStates: [Bool] = []
        presenter.fullScreenStateHandler = { state in
            publishedStates.append(state)
        }

        presenter.attach(attachedWindow)

        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification,
            object: unrelatedWindow
        )

        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification,
            object: attachedWindow
        )
        NotificationCenter.default.post(
            name: NSWindow.didExitFullScreenNotification,
            object: attachedWindow
        )

        XCTAssertEqual(publishedStates, [false, true, false])
    }

    func testFullScreenTransitionsDoNotInstallTitleBarAccessories() {
        let window = makeWindow()
        let presenter = MacMainWindowPresenter()

        presenter.attach(window)

        for notificationName in [
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ] {
            NotificationCenter.default.post(
                name: notificationName,
                object: window
            )
            XCTAssertTrue(
                window.titlebarAccessoryViewControllers.isEmpty
            )
        }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
    }
}
