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
        let presenter = MacMainWindowPresenter()

        presenter.attach(window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(
            window.minSize,
            NSSize(
                width: AppConfiguration.minimumWindowWidth,
                height: AppConfiguration.minimumWindowHeight
            )
        )
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

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
