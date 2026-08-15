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
        static let recoveryDebounceNanoseconds: UInt64 = 60_000_000
        static let refreshIntervalNanoseconds: UInt64 = 40_000_000
        static let windowTransitionNanoseconds: UInt64 = 20_000_000
        static let eventPropagationNanoseconds: UInt64 = 500_000_000
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

        let windows = Array(host.hostedProbeWindows.values)
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
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [true, false])
    }

    func testMostlyCoveredDisplayPausesWithOneTransparentColumn()
        async throws {
        let notificationCenter = NotificationCenter()
        let visibility = TestDesktopWindowVisibility()
        let host = makeHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            visibility: visibility
        )
        _ = host.prepare(contentMode: .contain)
        host.reveal()
        defer { host.close() }

        let probeGroups = Array(host.hostedProbeWindows.values)
        let firstDisplayProbes = probeGroups[0]
        let secondDisplayProbes = probeGroups[1]
        visibility.setVisible(false, for: firstDisplayProbes)
        visibility.setVisible(false, for: secondDisplayProbes)
        let transparentColumnIndexes = [0, 4, 8]
        transparentColumnIndexes.forEach {
            visibility.setVisible(true, for: firstDisplayProbes[$0])
        }
        postOcclusionChange(
            for: firstDisplayProbes + secondDisplayProbes,
            to: notificationCenter
        )

        try await waitForEventPropagation()
        XCTAssertTrue(host.isDesktopOccluded)
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

        let windows = Array(host.hostedProbeWindows.values)
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
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOcclusionDebouncePending)
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertTrue(states.isEmpty)
    }

    func testBriefVisibleGapDuringWindowSwitchKeepsDesktopSuspended()
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
        defer { host.close() }

        let windows = Array(host.hostedProbeWindows.values)
        windows.forEach { visibility.setVisible(false, for: $0) }
        windows.forEach {
            postOcclusionChange(for: $0, to: notificationCenter)
        }
        await waitUntil {
            host.isDesktopOccluded
        }
        XCTAssertTrue(host.isDesktopOccluded)
        states.removeAll()

        visibility.setVisible(true, for: windows[0])
        postOcclusionChange(for: windows[0], to: notificationCenter)
        try await Task.sleep(
            nanoseconds: TestConfiguration.windowTransitionNanoseconds
        )
        visibility.setVisible(false, for: windows[0])
        postOcclusionChange(for: windows[0], to: notificationCenter)
        try await waitForEventPropagation()

        XCTAssertTrue(host.isDesktopOccluded)
        XCTAssertTrue(states.isEmpty)
    }

    func testRefreshLoopCorrectsCoalescedOcclusionNotifications()
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
        defer { host.close() }

        let windows = Array(host.hostedProbeWindows.values)
        windows.forEach { visibility.setVisible(false, for: $0) }
        try await waitForEventPropagation()

        XCTAssertTrue(host.isDesktopOccluded)
        XCTAssertEqual(states, [true])

        visibility.setVisible(true, for: windows[0])
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [true, false])
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

        let windows = Array(host.hostedProbeWindows.values)
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

    func testPendingHotPlugDisplayIsTreatedAsVisibleUntilObservable()
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
            isProbeVisible: { visibility.isVisible($0) },
            displayIdentityResolver: { Self.displayID(for: $0) },
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
            host.hostedProbeWindows[
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
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])

        let secondSurface = try XCTUnwrap(surface.displaySurfaces.last)
        readiness.markReady(secondSurface)
        try await waitForEventPropagation()

        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])
    }

    func testPendingReplacementDisplayDoesNotPublishFalseOcclusion()
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
            isProbeVisible: { visibility.isVisible($0) },
            displayIdentityResolver: { Self.displayID(for: $0) },
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
            host.hostedProbeWindows[
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
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])

        readiness.markReady(try XCTUnwrap(surface.displaySurfaces.first))
        try await waitForEventPropagation()
        XCTAssertFalse(host.isDesktopOccluded)
        XCTAssertEqual(states, [false])
    }

    func testEffectiveDesktopRectUsesVisibleFrameInsetsAndSafeFallback() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1_000, height: 760)

        XCTAssertEqual(
            DesktopOcclusionGeometry.effectiveDesktopRect(
                visibleFrame: visibleFrame,
                screenFrame: screenFrame
            ),
            NSRect(x: 24, y: 56, width: 952, height: 728)
        )
        XCTAssertEqual(
            DesktopOcclusionGeometry.effectiveDesktopRect(
                visibleFrame: NSRect(x: 10, y: 10, width: 40, height: 20),
                screenFrame: NSRect(x: 0, y: 0, width: 80, height: 60)
            ),
            NSRect(x: 10, y: 10, width: 40, height: 20)
        )
    }

    func testProbeSamplingRequiresThreeQuartersCoverage() {
        let probeCount = DesktopOcclusionPolicy.probeColumnCount
            * DesktopOcclusionPolicy.probeRowCount
        var visibility = Array(repeating: true, count: probeCount)
        for index in 0..<8 {
            visibility[index] = false
        }
        XCTAssertFalse(
            DesktopOcclusionSampling.isEffectivelyOccluded(
                probeVisibility: visibility
            )
        )

        visibility[8] = false
        XCTAssertTrue(
            DesktopOcclusionSampling.isEffectivelyOccluded(
                probeVisibility: visibility
            )
        )
        XCTAssertFalse(
            DesktopOcclusionSampling.isEffectivelyOccluded(
                probeVisibility: Array(visibility.dropLast())
            )
        )
    }

    func testProbeGridSamplesTwelveDistributedInteriorRegions() {
        let effectiveRect = NSRect(x: 24, y: 16, width: 960, height: 720)
        let probeRects = DesktopOcclusionGeometry.probeRects(
            in: effectiveRect
        )

        XCTAssertEqual(probeRects.count, 12)
        XCTAssertTrue(probeRects.allSatisfy { effectiveRect.contains($0) })
        XCTAssertEqual(Set(probeRects.map(\.midX)).count, 4)
        XCTAssertEqual(Set(probeRects.map(\.midY)).count, 3)
    }

    func testScreenParameterChangeUpdatesProbeToLatestVisibleFrame() async {
        let notificationCenter = NotificationCenter()
        let provider = TestEnergyDisplayProvider(
            displays: [
                MacDesktopDisplay(
                    id: TestConfiguration.firstDisplayID,
                    frame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                    visibleFrame: NSRect(
                        x: 0,
                        y: 40,
                        width: 1_000,
                        height: 760
                    )
                )
            ]
        )
        let host = MacDesktopHost(
            notificationCenter: notificationCenter,
            workspaceCenter: NotificationCenter(),
            displaysProvider: { provider.displays },
            isSurfaceReady: { _ in true },
            isProbeVisible: { _ in true },
            displayIdentityResolver: { Self.displayID(for: $0) }
        )
        _ = host.prepare(contentMode: .contain)
        defer { host.close() }

        let runtimeID = MacDesktopDisplayID(
            rawValue: TestConfiguration.firstDisplayID
        )
        assertProbeFramesEqual(
            host.hostedProbeWindows[runtimeID]?.map(\.frame),
            DesktopOcclusionGeometry.probeRects(
                in: NSRect(x: 24, y: 56, width: 952, height: 728)
            )
        )

        provider.displays = [
            MacDesktopDisplay(
                id: TestConfiguration.firstDisplayID,
                frame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                visibleFrame: NSRect(
                    x: 80,
                    y: 0,
                    width: 920,
                    height: 800
                )
            )
        ]
        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        await Task.yield()

        assertProbeFramesEqual(
            host.hostedProbeWindows[runtimeID]?.map(\.frame),
            DesktopOcclusionGeometry.probeRects(
                in: NSRect(x: 104, y: 16, width: 872, height: 768)
            )
        )
    }

    private func assertProbeFramesEqual(
        _ actualFrames: [NSRect]?,
        _ expectedFrames: [NSRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actualFrames else {
            XCTFail("Missing probe frames", file: file, line: line)
            return
        }
        XCTAssertEqual(
            actualFrames.count,
            expectedFrames.count,
            file: file,
            line: line
        )
        for (actual, expected) in zip(actualFrames, expectedFrames) {
            XCTAssertEqual(
                actual.midX,
                expected.midX,
                accuracy: 1,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actual.midY,
                expected.midY,
                accuracy: 1,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actual.width,
                expected.width,
                accuracy: 1,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actual.height,
                expected.height,
                accuracy: 1,
                file: file,
                line: line
            )
        }
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
            isProbeVisible: { visibility.isVisible($0) },
            displayIdentityResolver: { Self.displayID(for: $0) },
            occlusionDebounceNanoseconds:
                TestConfiguration.debounceNanoseconds,
            visibilityRecoveryDebounceNanoseconds:
                TestConfiguration.recoveryDebounceNanoseconds,
            visibilityRefreshIntervalNanoseconds:
                TestConfiguration.refreshIntervalNanoseconds
        )
    }

    private func postOcclusionChange(
        for window: DesktopOcclusionProbeWindow,
        to notificationCenter: NotificationCenter
    ) {
        notificationCenter.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    private func postOcclusionChange(
        for windows: [DesktopOcclusionProbeWindow],
        to notificationCenter: NotificationCenter
    ) {
        guard let representativeWindow = windows.first else {
            return
        }
        postOcclusionChange(
            for: representativeWindow,
            to: notificationCenter
        )
    }

    private func waitForEventPropagation() async throws {
        try await Task.sleep(
            nanoseconds: TestConfiguration.eventPropagationNanoseconds
        )
    }

    private static func displayID(
        for display: MacDesktopDisplay
    ) -> DesktopDisplayID {
        DesktopDisplayID(rawValue: String(display.id.rawValue))
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let pollIntervalNanoseconds: UInt64 = 10_000_000
        let timeoutNanoseconds: UInt64 = 2_000_000_000
        var elapsedNanoseconds: UInt64 = 0
        while !condition(), elapsedNanoseconds < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            elapsedNanoseconds += pollIntervalNanoseconds
        }
        XCTAssertTrue(condition())
    }
}

private final class TestDesktopWindowVisibility {
    private var hiddenWindowIDs: Set<ObjectIdentifier> = []

    func setVisible(
        _ isVisible: Bool,
        for window: DesktopOcclusionProbeWindow
    ) {
        let identifier = ObjectIdentifier(window)
        if isVisible {
            hiddenWindowIDs.remove(identifier)
        } else {
            hiddenWindowIDs.insert(identifier)
        }
    }

    func setVisible(
        _ isVisible: Bool,
        for windows: [DesktopOcclusionProbeWindow]
    ) {
        windows.forEach { setVisible(isVisible, for: $0) }
    }

    func isVisible(_ window: DesktopOcclusionProbeWindow) -> Bool {
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
