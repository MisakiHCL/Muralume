import AppKit
import XCTest
@testable import Muralume

@MainActor
final class SystemLifecycleMonitorTests: XCTestCase {
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

        for _ in 0..<20 where events.count < expectedEvents.count {
            await Task.yield()
        }
        XCTAssertEqual(events.count, expectedEvents.count)
        for (event, expected) in zip(events, expectedEvents) {
            XCTAssertEqual(event.0, expected.0)
            XCTAssertEqual(event.1, expected.1)
        }
    }
}
