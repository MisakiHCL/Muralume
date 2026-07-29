import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SystemLifecycleMonitor: SystemLifecycleMonitoring {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var isRunning = false

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(
            workspaceCenter,
            name: NSWorkspace.screensDidSleepNotification,
            reason: .displaySleeping,
            suspended: true
        )
        observe(
            workspaceCenter,
            name: NSWorkspace.screensDidWakeNotification,
            reason: .displaySleeping,
            suspended: false
        )
        observe(
            workspaceCenter,
            name: NSWorkspace.willSleepNotification,
            reason: .systemSleeping,
            suspended: true
        )
        observe(
            workspaceCenter,
            name: NSWorkspace.didWakeNotification,
            reason: .systemSleeping,
            suspended: false
        )
        observe(
            workspaceCenter,
            name: NSWorkspace.sessionDidResignActiveNotification,
            reason: .sessionInactive,
            suspended: true
        )
        observe(
            workspaceCenter,
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            reason: .sessionInactive,
            suspended: false
        )

        let distributedCenter = DistributedNotificationCenter.default()
        observe(
            distributedCenter,
            name: SystemNotificationName.screenLocked,
            reason: .screenLocked,
            suspended: true
        )
        observe(
            distributedCenter,
            name: SystemNotificationName.screenUnlocked,
            reason: .screenLocked,
            suspended: false
        )

        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentThermalState()
            }
        }
        defaultObservers.append(thermalObserver)

        publishInitialSessionState()
        publishInitialDisplayState()
        publishCurrentThermalState()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        distributedObservers.removeAll()

        defaultObservers.forEach(NotificationCenter.default.removeObserver)
        defaultObservers.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        reason: PlaybackSuspensionReason,
        suspended: Bool
    ) {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspensionHandler?(reason, suspended)
            }
        }
        workspaceObservers.append(observer)
    }

    private func observe(
        _ center: DistributedNotificationCenter,
        name: Notification.Name,
        reason: PlaybackSuspensionReason,
        suspended: Bool
    ) {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspensionHandler?(reason, suspended)
            }
        }
        distributedObservers.append(observer)
    }

    private func publishCurrentThermalState() {
        let thermalState = ProcessInfo.processInfo.thermalState
        let isPressured = thermalState == .serious || thermalState == .critical
        suspensionHandler?(.thermalPressure, isPressured)
    }

    private func publishInitialSessionState() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return
        }
        let isOnConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let isLoggedIn = session[kCGSessionLoginDoneKey as String] as? Bool ?? true
        suspensionHandler?(.sessionInactive, !(isOnConsole && isLoggedIn))
    }

    private func publishInitialDisplayState() {
        let isDisplaySleeping = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        suspensionHandler?(.displaySleeping, isDisplaySleeping)
    }
}
