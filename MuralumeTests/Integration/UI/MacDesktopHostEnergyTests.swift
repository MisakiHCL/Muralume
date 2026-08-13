import AppKit
import CoreGraphics
import XCTest
@testable import Muralume

@MainActor
final class MacDesktopHostEnergyTests: XCTestCase {
    private enum TestConfiguration {
        static let firstDisplayID: CGDirectDisplayID = 401
        static let secondDisplayID: CGDirectDisplayID = 402
        static let debounceNanoseconds: UInt64 = 100_000_000
        static let eventPropagationNanoseconds: UInt64 = 180_000_000
    }

    func testAllDisplaysMustBeOccludedBeforePublishingSuspension()
        async throws {
        let notificationCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let host = makeHost(
            notificationCenter: notificationCenter,
            workspaceCenter: workspaceCenter,
            visibility: visibility
        )
        var states: [Bool] = []
        host.desktopOcclusionHandler = { states.append($0) }
        _ = host.prepare(contentMode: .contain)
        host.reveal()
        states.removeAll()
        defer { host.close() }

        let windows = Array(host.hostedWindows.values)
        visibility.setVisible(false, for: windows[0])
        postOcclusionChange(for: windows[0], to: notificationCenter)
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)

        visibility.setVisible(false, for: windows[1])
        postOcclusionChange(for: windows[1], to: notificationCenter)
        try await waitForEventPropagation()
        XCTAssertTrue(host.isDesktopOccluded)
        XCTAssertEqual(states, [true])

        visibility.setVisible(true, for: windows[0])
        postOcclusionChange(for: windows[0], to: notificationCenter)
        await waitUntil {
            !host.isDesktopOccluded
        }
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [true, false])
    }

    func testTransientOcclusionIsCancelledDuringDebounce() async throws {
        let notificationCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let host = makeHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            visibility: visibility
        )
        var states: [Bool] = []
        host.desktopOcclusionHandler = { states.append($0) }
        _ = host.prepare(contentMode: .contain)
        host.reveal()
        states.removeAll()
        defer { host.close() }

        let windows = Array(host.hostedWindows.values)
        windows.forEach { visibility.setVisible(false, for: $0) }
        windows.forEach {
            postOcclusionChange(for: $0, to: notificationCenter)
        }
        await waitUntil {
            host.isDesktopOcclusionDebouncePending
        }
        XCTAssertTrue(host.isDesktopOcclusionDebouncePending)

        visibility.setVisible(true, for: windows[0])
        postOcclusionChange(for: windows[0], to: notificationCenter)
        await waitUntil {
            !host.isDesktopOcclusionDebouncePending
        }
        XCTAssertFalse(host.isDesktopOcclusionDebouncePending)
        XCTAssertTrue(states.isEmpty)

        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertTrue(states.isEmpty)
    }

    func testCloseCancelsPendingOcclusionWithoutPublishingSuspension()
        async throws {
        let notificationCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let host = makeHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            visibility: visibility
        )
        var states: [Bool] = []
        host.desktopOcclusionHandler = { states.append($0) }
        _ = host.prepare(contentMode: .contain)
        host.reveal()
        states.removeAll()

        let windows = Array(host.hostedWindows.values)
        windows.forEach { visibility.setVisible(false, for: $0) }
        windows.forEach {
            postOcclusionChange(for: $0, to: notificationCenter)
        }
        await waitUntil {
            host.isDesktopOcclusionDebouncePending
        }
        XCTAssertTrue(host.isDesktopOcclusionDebouncePending)

        host.close()
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertFalse(host.isDesktopOcclusionDebouncePending)
        XCTAssertTrue(states.isEmpty)
    }

    func testPendingHotPlugDisplayDoesNotDisableExistingOcclusion()
        async throws {
        let notificationCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let readiness = TestDesktopSurfaceReadiness()
        let provider = TestEnergyDisplayProvider(
            displays: [
                MacDesktopDisplay(
                    id: TestConfiguration.firstDisplayID,
                    frame: NSRect(x: 0, y: 0, width: 640, height: 360)
                )
            ]
        )
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            displaysProvider: { provider.displays },
            isSurfaceReady: { readiness.isReady($0) },
            isWindowVisible: { visibility.isVisible($0) },
            occlusionDebounceNanoseconds:
                TestConfiguration.debounceNanoseconds
        )
        var states: [Bool] = []
        host.desktopOcclusionHandler = { states.append($0) }
        let preparedSurface = host.prepare(contentMode: .contain)
        let surface = try XCTUnwrap(
            preparedSurface as? DesktopPlayerLayerSurfaceGroup
        )
        readiness.markReady(try XCTUnwrap(surface.displaySurfaces.first))
        host.reveal()
        defer { host.close() }

        let firstWindow = try XCTUnwrap(
            host.hostedWindows[
                MacDesktopDisplayID(rawValue: TestConfiguration.firstDisplayID)
            ]
        )
        visibility.setVisible(false, for: firstWindow)
        postOcclusionChange(for: firstWindow, to: notificationCenter)
        try await waitForEventPropagation()
        XCTAssertTrue(host.isDesktopOccluded)
        states.removeAll()

        provider.displays.append(
            MacDesktopDisplay(
                id: TestConfiguration.secondDisplayID,
                frame: NSRect(x: 640, y: 0, width: 640, height: 360)
            )
        )
        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        try await waitForEventPropagation()

        XCTAssertEqual(host.hostedWindowCount, 2)
        XCTAssertTrue(host.isDesktopOccluded)
        XCTAssertTrue(states.isEmpty)

        let secondSurface = try XCTUnwrap(surface.displaySurfaces.last)
        readiness.markReady(secondSurface)
        try await waitForEventPropagation()

        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])
    }

    func testPendingReplacementDisplayPreservesLastOcclusionState()
        async throws {
        let notificationCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let readiness = TestDesktopSurfaceReadiness()
        let provider = TestEnergyDisplayProvider(
            displays: [
                MacDesktopDisplay(
                    id: TestConfiguration.firstDisplayID,
                    frame: NSRect(x: 0, y: 0, width: 640, height: 360)
                )
            ]
        )
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            displaysProvider: { provider.displays },
            isSurfaceReady: { readiness.isReady($0) },
            isWindowVisible: { visibility.isVisible($0) },
            occlusionDebounceNanoseconds:
                TestConfiguration.debounceNanoseconds
        )
        var states: [Bool] = []
        host.desktopOcclusionHandler = { states.append($0) }
        let preparedSurface = host.prepare(contentMode: .contain)
        let surface = try XCTUnwrap(
            preparedSurface as? DesktopPlayerLayerSurfaceGroup
        )
        readiness.markReady(try XCTUnwrap(surface.displaySurfaces.first))
        host.reveal()
        defer { host.close() }

        let firstWindow = try XCTUnwrap(
            host.hostedWindows[
                MacDesktopDisplayID(rawValue: TestConfiguration.firstDisplayID)
            ]
        )
        visibility.setVisible(false, for: firstWindow)
        postOcclusionChange(for: firstWindow, to: notificationCenter)
        try await waitForEventPropagation()
        XCTAssertTrue(host.isDesktopOccluded)
        states.removeAll()

        provider.displays = [
            MacDesktopDisplay(
                id: TestConfiguration.secondDisplayID,
                frame: NSRect(x: 0, y: 0, width: 640, height: 360)
            )
        ]
        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        try await waitForEventPropagation()

        XCTAssertEqual(host.hostedWindowCount, 1)
        XCTAssertTrue(host.isDesktopOccluded)
        XCTAssertTrue(states.isEmpty)

        readiness.markReady(try XCTUnwrap(surface.displaySurfaces.first))
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])
    }

    private func makeHost(
        notificationCenter: NotificationCenter,
        workspaceCenter: NotificationCenter,
        visibility: TestDesktopWindowVisibility
    ) -> MacDesktopHost {
        MacDesktopHost(
            notificationCenter: notificationCenter,
            workspaceCenter: workspaceCenter,
            displaysProvider: {
                [
                    MacDesktopDisplay(
                        id: TestConfiguration.firstDisplayID,
                        frame: NSRect(x: 0, y: 0, width: 640, height: 360)
                    ),
                    MacDesktopDisplay(
                        id: TestConfiguration.secondDisplayID,
                        frame: NSRect(x: 640, y: 0, width: 640, height: 360)
                    )
                ]
            },
            isSurfaceReady: { _ in true },
            isWindowVisible: { visibility.isVisible($0) },
            occlusionDebounceNanoseconds:
                TestConfiguration.debounceNanoseconds
        )
    }

    private func postOcclusionChange(
        for window: DesktopWindow,
        to notificationCenter: NotificationCenter
    ) {
        notificationCenter.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    private func waitForEventPropagation() async throws {
        try await Task.sleep(
            nanoseconds: TestConfiguration.eventPropagationNanoseconds
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<50 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private final class TestDesktopWindowVisibility {
    private var hiddenWindowIDs: Set<ObjectIdentifier> = []

    func setVisible(_ isVisible: Bool, for window: DesktopWindow) {
        let identifier = ObjectIdentifier(window)
        if isVisible {
            hiddenWindowIDs.remove(identifier)
        } else {
            hiddenWindowIDs.insert(identifier)
        }
    }

    func isVisible(_ window: DesktopWindow) -> Bool {
        !hiddenWindowIDs.contains(ObjectIdentifier(window))
    }
}

@MainActor
private final class TestDesktopSurfaceReadiness {
    private var readySurfaceIDs: Set<ObjectIdentifier> = []

    func markReady(_ surface: DesktopPlayerLayerSurfaceView) {
        readySurfaceIDs.insert(ObjectIdentifier(surface))
    }

    func isReady(_ surface: DesktopPlayerLayerSurfaceView) -> Bool {
        readySurfaceIDs.contains(ObjectIdentifier(surface))
    }
}

@MainActor
private final class TestEnergyDisplayProvider {
    var displays: [MacDesktopDisplay]

    init(displays: [MacDesktopDisplay]) {
        self.displays = displays
    }
}
