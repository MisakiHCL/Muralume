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

    func testDismissHidesBoundWindowWithoutClosingIt() async {
        let window = makeWindow()
        let presenter = MacMainWindowPresenter()
        var unexpectedCloseCount = 0
        presenter.unexpectedWindowCloseHandler = {
            unexpectedCloseCount += 1
        }
        presenter.attach(window)
        window.orderFront(nil)
        let willClose = expectation(
            forNotification: NSWindow.willCloseNotification,
            object: window
        )
        willClose.isInverted = true

        presenter.dismiss()

        await fulfillment(of: [willClose], timeout: 0.1)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(presenter.isPresenting(window))
        XCTAssertEqual(unexpectedCloseCount, 0)
    }

    func testShowRestoresTheSameDismissedWindow() {
        let window = makeWindow()
        let presenter = MacMainWindowPresenter()
        presenter.attach(window)
        window.orderFront(nil)

        presenter.dismiss()
        presenter.show()

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(presenter.isPresenting(window))
        window.orderOut(nil)
    }

    func testShowRestoresMiniaturizedBoundWindow() async {
        let window = makeWindow()
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

        let didDeminiaturize = expectation(
            forNotification: NSWindow.didDeminiaturizeNotification,
            object: window
        )
        presenter.show()

        await fulfillment(of: [didDeminiaturize], timeout: 2)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
        window.orderOut(nil)
    }

    func testWindowIdentityMatchesOnlyAttachedMainWindow() {
        let attachedWindow = makeWindow()
        let unrelatedWindow = makeWindow()
        let presenter = MacMainWindowPresenter()

        presenter.attach(attachedWindow)

        XCTAssertTrue(presenter.isPresenting(attachedWindow))
        XCTAssertFalse(presenter.isPresenting(unrelatedWindow))
        XCTAssertFalse(presenter.isPresenting(nil))
    }

    func testAttachingReplacementWindowHidesThePreviousInstance() {
        let firstWindow = makeWindow()
        let replacementWindow = makeWindow()
        let presenter = MacMainWindowPresenter()
        presenter.attach(firstWindow)
        firstWindow.orderFront(nil)

        presenter.attach(replacementWindow)

        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertFalse(presenter.isPresenting(firstWindow))
        XCTAssertTrue(presenter.isPresenting(replacementWindow))
    }

    func testUnexpectedAttachedMainWindowCloseIsObservedOnce() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let presenter = MacMainWindowPresenter()
        var closeCount = 0
        presenter.unexpectedWindowCloseHandler = {
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

    func testTitleBarInteractionDragsAndZoomsThroughAppKit() throws {
        let window = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let interactionView = MuralumeTitleBarInteractionNSView()
        window.contentView = interactionView
        XCTAssertTrue(interactionView.acceptsFirstMouse(for: nil))
        XCTAssertFalse(interactionView.mouseDownCanMoveWindow)

        interactionView.mouseDown(
            with: try makeMouseDownEvent(
                for: window,
                clickCount: 1
            )
        )
        interactionView.mouseDown(
            with: try makeMouseDownEvent(
                for: window,
                clickCount: 2
            )
        )

        XCTAssertEqual(window.performDragCount, 1)
        XCTAssertEqual(window.performZoomCount, 1)
    }

    func testTitleBarInteractionDoesNotZoomFixedSizeWindow() throws {
        let window = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let interactionView = MuralumeTitleBarInteractionNSView()
        window.contentView = interactionView

        interactionView.mouseDown(
            with: try makeMouseDownEvent(
                for: window,
                clickCount: 2
            )
        )

        XCTAssertEqual(window.performDragCount, 0)
        XCTAssertEqual(window.performZoomCount, 0)
    }

    func testTitleBarInteractionDoesNothingInFullScreen() throws {
        let window = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.styleMaskOverride = [.titled, .resizable, .fullScreen]
        let interactionView = MuralumeTitleBarInteractionNSView()
        window.contentView = interactionView

        interactionView.mouseDown(
            with: try makeMouseDownEvent(
                for: window,
                clickCount: 1
            )
        )
        interactionView.mouseDown(
            with: try makeMouseDownEvent(
                for: window,
                clickCount: 2
            )
        )

        XCTAssertEqual(window.performDragCount, 0)
        XCTAssertEqual(window.performZoomCount, 0)
    }

    private func makeMouseDownEvent(
        for window: NSWindow,
        clickCount: Int
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 160, y: 20),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )
        )
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

@MainActor
private final class RecordingWindow: NSWindow {
    private(set) var performDragCount = 0
    private(set) var performZoomCount = 0
    var styleMaskOverride: NSWindow.StyleMask?

    override var styleMask: NSWindow.StyleMask {
        get {
            styleMaskOverride ?? super.styleMask
        }
        set {
            super.styleMask = newValue
        }
    }

    override func performDrag(with event: NSEvent) {
        performDragCount += 1
    }

    override func performZoom(_ sender: Any?) {
        performZoomCount += 1
    }
}
