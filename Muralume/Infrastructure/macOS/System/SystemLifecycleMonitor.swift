import AppKit
import CoreGraphics
import Foundation

private enum SystemDisplayKey {
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

enum DisplaySleepPolicy {
    static func shouldSuspend(
        displayIDs: [CGDirectDisplayID],
        isAsleep: (CGDirectDisplayID) -> Bool
    ) -> Bool {
        displayIDs.allSatisfy(isAsleep)
    }
}

enum ThermalPlaybackPolicy {
    static func shouldSuspend(for state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}

@MainActor
final class SystemLifecycleMonitor: SystemLifecycleMonitoring {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)?
    var energyConstrainedHandler: ((Bool) -> Void)?

    private let workspaceCenter: NotificationCenter
    private let defaultCenter: NotificationCenter
    private let thermalStateProvider: () -> ProcessInfo.ThermalState
    private let lowPowerModeProvider: () -> Bool
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var isRunning = false

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared
            .notificationCenter,
        defaultCenter: NotificationCenter = .default,
        thermalStateProvider: @escaping () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        lowPowerModeProvider: @escaping () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.workspaceCenter = workspaceCenter
        self.defaultCenter = defaultCenter
        self.thermalStateProvider = thermalStateProvider
        self.lowPowerModeProvider = lowPowerModeProvider
    }

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true

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

        let thermalObserver = defaultCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentThermalState()
            }
        }
        defaultObservers.append(thermalObserver)

        let powerStateObserver = defaultCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentPowerState()
            }
        }
        defaultObservers.append(powerStateObserver)

        let screenParametersObserver = defaultCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishInitialDisplayState()
            }
        }
        defaultObservers.append(screenParametersObserver)

        publishInitialSessionState()
        publishInitialDisplayState()
        publishCurrentThermalState()
        publishCurrentPowerState()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false

        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        defaultObservers.forEach(defaultCenter.removeObserver)
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

    private func publishCurrentThermalState() {
        suspensionHandler?(
            .thermalPressure,
            ThermalPlaybackPolicy.shouldSuspend(for: thermalStateProvider())
        )
    }

    private func publishCurrentPowerState() {
        energyConstrainedHandler?(lowPowerModeProvider())
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
        let displayIDs: [CGDirectDisplayID] = NSScreen.screens.compactMap {
            screen -> CGDirectDisplayID? in
            guard let displayID = (screen.deviceDescription[
                SystemDisplayKey.screenNumber
            ] as? NSNumber)?.uint32Value,
                  CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else {
                return nil
            }
            return displayID
        }
        let isDisplaySleeping = DisplaySleepPolicy.shouldSuspend(
            displayIDs: displayIDs,
            isAsleep: { CGDisplayIsAsleep($0) != 0 }
        )
        suspensionHandler?(.displaySleeping, isDisplaySleeping)
    }
}
