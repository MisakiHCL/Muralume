import AppKit
import XCTest
@testable import Muralume

@MainActor
final class SystemLifecycleMonitorTests: XCTestCase {
    private enum TestPolicy {
        static let eventPropagationAttempts = 20
    }

    func testPublicWorkspaceNotificationsUpdateSuspensionState() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter
        )
        var events: [(PlaybackSuspensionReason, Bool)] = []
        monitor.suspensionHandler = { reason, isSuspended in
            events.append((reason, isSuspended))
        }
        monitor.start()
        events.removeAll()
        defer {
            monitor.stop()
        }

        let expectedEvents: [(PlaybackSuspensionReason, Bool)] = [
            (.displaySleeping, true),
            (.displaySleeping, false),
            (.systemSleeping, true),
            (.systemSleeping, false),
            (.sessionInactive, true),
            (.sessionInactive, false)
        ]
        let notifications: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        notifications.forEach {
            workspaceCenter.post(name: $0, object: nil)
        }

        for _ in 0..<TestPolicy.eventPropagationAttempts
            where events.count < expectedEvents.count {
            await Task.yield()
        }
        XCTAssertEqual(events.count, expectedEvents.count)
        for (event, expected) in zip(events, expectedEvents) {
            XCTAssertEqual(event.0, expected.0)
            XCTAssertEqual(event.1, expected.1)
        }
    }

    func testThermalPolicySuspendsOnlyForSeriousAndCriticalStates() {
        XCTAssertFalse(ThermalPlaybackPolicy.shouldSuspend(for: .nominal))
        XCTAssertFalse(ThermalPlaybackPolicy.shouldSuspend(for: .fair))
        XCTAssertTrue(ThermalPlaybackPolicy.shouldSuspend(for: .serious))
        XCTAssertTrue(ThermalPlaybackPolicy.shouldSuspend(for: .critical))
    }

    func testThermalNotificationPublishesInjectedCurrentState() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        var thermalState = ProcessInfo.ThermalState.nominal
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter,
            thermalStateProvider: { thermalState }
        )
        var thermalSuspensions: [Bool] = []
        monitor.suspensionHandler = { reason, isSuspended in
            guard reason == .thermalPressure else {
                return
            }
            thermalSuspensions.append(isSuspended)
        }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(thermalSuspensions, [false])
        thermalSuspensions.removeAll()
        thermalState = .serious
        defaultCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo
        )

        for _ in 0..<TestPolicy.eventPropagationAttempts
            where thermalSuspensions.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(thermalSuspensions, [true])
    }

    func testLowPowerModePublishesConstraintWithoutSuspension() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        var isLowPowerModeEnabled = false
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter,
            lowPowerModeProvider: { isLowPowerModeEnabled }
        )
        var suspensionEvents: [(PlaybackSuspensionReason, Bool)] = []
        var energyConstraints: [Bool] = []
        monitor.suspensionHandler = { reason, isSuspended in
            suspensionEvents.append((reason, isSuspended))
        }
        monitor.energyConstrainedHandler = {
            energyConstraints.append($0)
        }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(energyConstraints, [false])
        suspensionEvents.removeAll()
        energyConstraints.removeAll()
        isLowPowerModeEnabled = true
        defaultCenter.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo
        )

        for _ in 0..<TestPolicy.eventPropagationAttempts
            where energyConstraints.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(energyConstraints, [true])
        XCTAssertTrue(suspensionEvents.isEmpty)
    }
}
