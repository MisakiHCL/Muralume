import AVFoundation
import AppKit
import CoreGraphics
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
final class MacDesktopHostTests: XCTestCase {
    private enum TestConfiguration {
        static let firstDisplayID: CGDirectDisplayID = 101
        static let secondDisplayID: CGDirectDisplayID = 202
        static let thirdDisplayID: CGDirectDisplayID = 303
        static let hiddenAlpha: CGFloat = 0.01
        static let visibleAlpha: CGFloat = 1
        static let alphaAccuracy: CGFloat = 0.001
        static let topologyGracePeriodNanoseconds: UInt64 = 200_000_000
        static let pollIntervalNanoseconds: UInt64 = 10_000_000
        static let conditionTimeoutNanoseconds: UInt64 = 2_000_000_000
        static let stabilityDurationNanoseconds: UInt64 = 300_000_000
        static let deferredRevealMarginNanoseconds: UInt64 = 200_000_000
        static let deferredRevealRecoveryTimeoutNanoseconds: UInt64 =
            5_000_000_000
    }

    func testHotPlugWaitsForReadinessAndTopologyUpdatesAreIdempotent()
        async throws {
        let notificationCenter = NotificationCenter()
        let firstFrame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let secondFrame = NSRect(x: 640, y: 0, width: 800, height: 450)
        let provider = TestDesktopDisplayProvider(
            displays: [
                MacDesktopDisplay(
                    id: TestConfiguration.firstDisplayID,
                    frame: firstFrame
                ),
                MacDesktopDisplay(
                    id: TestConfiguration.secondDisplayID,
                    frame: secondFrame
                )
            ]
        )
        let readiness = TestDesktopSurfaceReadiness()
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            displaysProvider: { provider.currentDisplays() },
            isSurfaceReady: { readiness.isReady($0) },
            emptyTopologyGracePeriodNanoseconds:
                TestConfiguration.topologyGracePeriodNanoseconds
        )
        let preparedSurface = host.prepare(contentMode: .contain)
        let surface = try XCTUnwrap(
            preparedSurface as? DesktopPlayerLayerSurfaceGroup
        )
        defer { host.close() }

        XCTAssertEqual(
            host.hostedDisplayIDs,
            Set([
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.firstDisplayID
                ),
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.secondDisplayID
                )
            ])
        )
        XCTAssertEqual(host.hostedWindowCount, 2)
        XCTAssertEqual(
            host.hostedWindowFrames[
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.firstDisplayID
                )
            ],
            firstFrame
        )
        XCTAssertEqual(
            host.hostedWindowFrames[
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.secondDisplayID
                )
            ],
            secondFrame
        )
        XCTAssertEqual(surface.displaySurfaces.count, 2)
        XCTAssertTrue(
            surface.displaySurfaces.allSatisfy {
                $0.contentMode == .contain
            }
        )
        assertAlphaValues(
            host.hostedWindowAlphaValues,
            expectedCount: 2,
            equalTo: TestConfiguration.hiddenAlpha
        )

        let firstSurfaceIdentity = ObjectIdentifier(surface.displaySurfaces[0])
        weak var removedSurface = surface.displaySurfaces[1]
        let removedSurfaceIdentity = ObjectIdentifier(
            try XCTUnwrap(removedSurface)
        )
        surface.displaySurfaces.forEach(readiness.markReady)
        host.reveal()
        assertAlphaValues(
            host.hostedWindowAlphaValues,
            expectedCount: 2,
            equalTo: TestConfiguration.visibleAlpha
        )

        let updatedFirstFrame = NSRect(
            x: -1_024,
            y: -128,
            width: 1_024,
            height: 768
        )
        let thirdFrame = NSRect(x: 0, y: 0, width: 1_280, height: 720)
        provider.displays = [
            MacDesktopDisplay(
                id: TestConfiguration.firstDisplayID,
                frame: updatedFirstFrame
            ),
            MacDesktopDisplay(
                id: TestConfiguration.thirdDisplayID,
                frame: thirdFrame
            )
        ]
        postTopologyChange(to: notificationCenter)
        try await waitUntil("hot-plugged display topology") {
            host.hostedDisplayIDs == Set([
                self.displayID(TestConfiguration.firstDisplayID),
                self.displayID(TestConfiguration.thirdDisplayID)
            ])
        }

        XCTAssertEqual(
            host.hostedDisplayIDs,
            Set([
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.firstDisplayID
                ),
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.thirdDisplayID
                )
            ])
        )
        XCTAssertEqual(host.hostedWindowCount, 2)
        XCTAssertEqual(
            host.hostedWindowFrames[
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.firstDisplayID
                )
            ],
            updatedFirstFrame
        )
        XCTAssertEqual(
            host.hostedWindowFrames[
                MacDesktopDisplayID(
                    rawValue: TestConfiguration.thirdDisplayID
                )
            ],
            thirdFrame
        )
        XCTAssertEqual(
            ObjectIdentifier(surface.displaySurfaces[0]),
            firstSurfaceIdentity
        )
        XCTAssertFalse(
            surface.displaySurfaces
                .map(ObjectIdentifier.init)
                .contains(removedSurfaceIdentity)
        )
        try await waitUntil("removed display surface release") {
            removedSurface == nil
        }
        XCTAssertEqual(
            try XCTUnwrap(
                host.hostedWindowAlphaValues[
                    displayID(TestConfiguration.firstDisplayID)
                ]
            ),
            TestConfiguration.visibleAlpha,
            accuracy: TestConfiguration.alphaAccuracy
        )
        XCTAssertEqual(
            try XCTUnwrap(
                host.hostedWindowAlphaValues[
                    displayID(TestConfiguration.thirdDisplayID)
                ]
            ),
            TestConfiguration.hiddenAlpha,
            accuracy: TestConfiguration.alphaAccuracy
        )

        let thirdSurface = surface.displaySurfaces[1]
        XCTAssertFalse(readiness.isReady(thirdSurface))
        readiness.markReady(thirdSurface)
        try await waitUntil("hot-plugged display reveal") {
            self.alpha(
                for: TestConfiguration.thirdDisplayID,
                in: host
            ) == TestConfiguration.visibleAlpha
        }

        host.setVideoContentMode(.cover)
        XCTAssertTrue(
            surface.displaySurfaces.allSatisfy {
                $0.contentMode == .cover
            }
        )
        let stableSurfaceIdentities = surface.displaySurfaces.map(
            ObjectIdentifier.init
        )
        let stableFrames = host.hostedWindowFrames
        let providerReadCount = provider.readCount
        provider.displays.reverse()
        postTopologyChange(to: notificationCenter)
        try await waitUntil("duplicate topology notification") {
            provider.readCount > providerReadCount
        }

        XCTAssertEqual(
            surface.displaySurfaces.map(ObjectIdentifier.init),
            stableSurfaceIdentities
        )
        XCTAssertEqual(host.hostedWindowFrames, stableFrames)
    }

    func testRevealKeepsDisplayAddedAfterAttachHiddenUntilReady()
        async throws {
        let notificationCenter = NotificationCenter()
        let firstFrame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let secondFrame = NSRect(x: 640, y: 0, width: 800, height: 450)
        let provider = TestDesktopDisplayProvider(
            displays: [
                MacDesktopDisplay(
                    id: TestConfiguration.firstDisplayID,
                    frame: firstFrame
                )
            ]
        )
        let readiness = TestDesktopSurfaceReadiness()
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            displaysProvider: { provider.currentDisplays() },
            isSurfaceReady: { readiness.isReady($0) },
            emptyTopologyGracePeriodNanoseconds:
                TestConfiguration.topologyGracePeriodNanoseconds
        )
        let preparedSurface = host.prepare(contentMode: .contain)
        let surface = try XCTUnwrap(
            preparedSurface as? DesktopPlayerLayerSurfaceGroup
        )
        defer { host.close() }
        let player = AVPlayer()
        surface.connect(to: player)
        let firstSurface = try XCTUnwrap(surface.displaySurfaces.first)
        readiness.markReady(firstSurface)

        let topologyReadStart = provider.readCount
        provider.displays.append(
            MacDesktopDisplay(
                id: TestConfiguration.secondDisplayID,
                frame: secondFrame
            )
        )
        postTopologyChange(to: notificationCenter)
        try await waitUntil("display added before reveal") {
            provider.readCount > topologyReadStart
                && host.hostedWindowCount == 2
                && surface.displaySurfaces.count == 2
        }

        let secondSurface = surface.displaySurfaces[1]
        let playerIdentity = ObjectIdentifier(player)
        XCTAssertEqual(
            firstSurface.connectedPlayerIdentity,
            playerIdentity
        )
        XCTAssertEqual(
            secondSurface.connectedPlayerIdentity,
            playerIdentity
        )
        assertAlphaValues(
            host.hostedWindowAlphaValues,
            expectedCount: 2,
            equalTo: TestConfiguration.hiddenAlpha
        )

        host.reveal()

        XCTAssertEqual(
            try XCTUnwrap(
                alpha(
                    for: TestConfiguration.firstDisplayID,
                    in: host
                )
            ),
            TestConfiguration.visibleAlpha,
            accuracy: TestConfiguration.alphaAccuracy
        )
        XCTAssertEqual(
            try XCTUnwrap(
                alpha(
                    for: TestConfiguration.secondDisplayID,
                    in: host
                )
            ),
            TestConfiguration.hiddenAlpha,
            accuracy: TestConfiguration.alphaAccuracy
        )
        try await assertRemains(
            "deferred display stays hidden after fast polling",
            durationNanoseconds:
                PlaybackPolicy.surfaceReadyTimeoutNanoseconds
                + TestConfiguration.deferredRevealMarginNanoseconds
        ) {
            self.alpha(
                for: TestConfiguration.secondDisplayID,
                in: host
            ) == TestConfiguration.hiddenAlpha
        }

        readiness.markReady(secondSurface)
        try await waitUntil(
            "deferred display becomes ready",
            timeoutNanoseconds:
                TestConfiguration.deferredRevealRecoveryTimeoutNanoseconds
        ) {
            self.alpha(
                for: TestConfiguration.secondDisplayID,
                in: host
            ) == TestConfiguration.visibleAlpha
        }
    }

    func testEmptyTopologyGraceReleasesAndRebuildsDisplays() async throws {
        let notificationCenter = NotificationCenter()
        let firstFrame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let secondFrame = NSRect(x: 640, y: 0, width: 800, height: 450)
        let originalDisplays = [
            MacDesktopDisplay(
                id: TestConfiguration.firstDisplayID,
                frame: firstFrame
            ),
            MacDesktopDisplay(
                id: TestConfiguration.secondDisplayID,
                frame: secondFrame
            )
        ]
        let provider = TestDesktopDisplayProvider(displays: originalDisplays)
        let readiness = TestDesktopSurfaceReadiness()
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            displaysProvider: { provider.currentDisplays() },
            isSurfaceReady: { readiness.isReady($0) },
            emptyTopologyGracePeriodNanoseconds:
                TestConfiguration.topologyGracePeriodNanoseconds
        )
        let preparedSurface = host.prepare(contentMode: .contain)
        let surface = try XCTUnwrap(
            preparedSurface as? DesktopPlayerLayerSurfaceGroup
        )
        defer { host.close() }

        surface.displaySurfaces.forEach(readiness.markReady)
        host.reveal()
        let originalSurfaceIdentities = surface.displaySurfaces.map(
            ObjectIdentifier.init
        )
        let emptyReadStart = provider.readCount

        provider.displays = []
        postTopologyChange(to: notificationCenter)
        try await waitUntil("transient empty topology observation") {
            provider.readCount > emptyReadStart
        }
        provider.displays = Array(originalDisplays.reversed())
        postTopologyChange(to: notificationCenter)
        try await assertRemains(
            "transient empty topology preserves display surfaces"
        ) {
            host.hostedWindowCount == 2
                && surface.displaySurfaces.map(ObjectIdentifier.init)
                    == originalSurfaceIdentities
        }

        XCTAssertEqual(host.hostedWindowCount, 2)
        XCTAssertEqual(
            surface.displaySurfaces.map(ObjectIdentifier.init),
            originalSurfaceIdentities
        )

        weak var firstRemovedSurface = surface.displaySurfaces[0]
        weak var secondRemovedSurface = surface.displaySurfaces[1]
        let stableEmptyReadStart = provider.readCount
        provider.displays = []
        postTopologyChange(to: notificationCenter)
        try await waitUntil("stable empty topology observation") {
            provider.readCount > stableEmptyReadStart
        }
        try await waitUntil("stable empty topology cleanup") {
            host.hostedWindowCount == 0 && surface.displaySurfaces.isEmpty
        }

        XCTAssertEqual(host.hostedWindowCount, 0)
        XCTAssertTrue(surface.displaySurfaces.isEmpty)
        try await waitUntil("first empty-topology surface release") {
            firstRemovedSurface == nil
        }
        try await waitUntil("second empty-topology surface release") {
            secondRemovedSurface == nil
        }

        let reconnectReadStart = provider.readCount
        provider.displays = [
            MacDesktopDisplay(
                id: TestConfiguration.secondDisplayID,
                frame: secondFrame
            )
        ]
        postTopologyChange(to: notificationCenter)
        try await waitUntil("display reconstruction") {
            provider.readCount > reconnectReadStart
                && host.hostedWindowCount == 1
                && surface.displaySurfaces.count == 1
        }

        let rebuiltSurface = try XCTUnwrap(surface.displaySurfaces.first)
        XCTAssertEqual(
            try XCTUnwrap(
                alpha(
                    for: TestConfiguration.secondDisplayID,
                    in: host
                )
            ),
            TestConfiguration.hiddenAlpha,
            accuracy: TestConfiguration.alphaAccuracy
        )
        readiness.markReady(rebuiltSurface)
        try await waitUntil("rebuilt display reveal") {
            self.alpha(
                for: TestConfiguration.secondDisplayID,
                in: host
            ) == TestConfiguration.visibleAlpha
        }

        host.close()
        let readCountAfterClose = provider.readCount
        provider.displays = originalDisplays
        postTopologyChange(to: notificationCenter)
        try await assertRemains("closed host ignores topology changes") {
            provider.readCount == readCountAfterClose
                && host.surface == nil
                && host.hostedWindowCount == 0
                && surface.displaySurfaces.isEmpty
        }
    }

    private func postTopologyChange(to notificationCenter: NotificationCenter) {
        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 =
            TestConfiguration.conditionTimeoutNanoseconds,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0

        while !condition() {
            guard elapsedNanoseconds < timeoutNanoseconds else {
                XCTFail(
                    "Timed out waiting for \(description)",
                    file: file,
                    line: line
                )
                return
            }
            try await Task.sleep(
                nanoseconds: TestConfiguration.pollIntervalNanoseconds
            )
            elapsedNanoseconds += TestConfiguration.pollIntervalNanoseconds
        }
    }

    private func assertRemains(
        _ description: String,
        durationNanoseconds: UInt64 =
            TestConfiguration.stabilityDurationNanoseconds,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        var elapsedNanoseconds: UInt64 = 0

        while elapsedNanoseconds < durationNanoseconds {
            guard condition() else {
                XCTFail(description, file: file, line: line)
                return
            }
            try await Task.sleep(
                nanoseconds: TestConfiguration.pollIntervalNanoseconds
            )
            elapsedNanoseconds += TestConfiguration.pollIntervalNanoseconds
        }
    }

    private func displayID(
        _ rawValue: CGDirectDisplayID
    ) -> MacDesktopDisplayID {
        MacDesktopDisplayID(rawValue: rawValue)
    }

    private func alpha(
        for displayID: CGDirectDisplayID,
        in host: MacDesktopHost
    ) -> CGFloat? {
        host.hostedWindowAlphaValues[self.displayID(displayID)]
    }

    private func assertAlphaValues(
        _ alphaValues: [MacDesktopDisplayID: CGFloat],
        expectedCount: Int,
        equalTo expectedValue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            alphaValues.count,
            expectedCount,
            file: file,
            line: line
        )
        alphaValues.values.forEach { alphaValue in
            XCTAssertEqual(
                alphaValue,
                expectedValue,
                accuracy: TestConfiguration.alphaAccuracy,
                file: file,
                line: line
            )
        }
    }
}

final class DisplaySleepPolicyTests: XCTestCase {
    func testSuspendsOnlyWhenEveryDisplayIsAsleep() {
        let firstDisplayID: CGDirectDisplayID = 11
        let secondDisplayID: CGDirectDisplayID = 22

        XCTAssertFalse(
            DisplaySleepPolicy.shouldSuspend(
                displayIDs: [firstDisplayID, secondDisplayID],
                isAsleep: { $0 == secondDisplayID }
            )
        )
        XCTAssertTrue(
            DisplaySleepPolicy.shouldSuspend(
                displayIDs: [firstDisplayID, secondDisplayID],
                isAsleep: { _ in true }
            )
        )
        XCTAssertTrue(
            DisplaySleepPolicy.shouldSuspend(
                displayIDs: [],
                isAsleep: { _ in false }
            )
        )
    }
}

@MainActor
private final class TestDesktopDisplayProvider {
    var displays: [MacDesktopDisplay]
    private(set) var readCount = 0

    init(displays: [MacDesktopDisplay]) {
        self.displays = displays
    }

    func currentDisplays() -> [MacDesktopDisplay] {
        readCount += 1
        return displays
    }
}

@MainActor
private final class TestDesktopSurfaceReadiness {
    private let readySurfaces = NSHashTable<
        DesktopPlayerLayerSurfaceView
    >.weakObjects()

    func isReady(_ surface: DesktopPlayerLayerSurfaceView) -> Bool {
        readySurfaces.contains(surface)
    }

    func markReady(_ surface: DesktopPlayerLayerSurfaceView) {
        readySurfaces.add(surface)
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
