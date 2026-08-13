import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import notify

private enum SystemDisplayKey {
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

enum SystemEnergyMonitoringPolicy {
    static let loadSampleInterval: TimeInterval = 5
    static let loadTimerTolerance: TimeInterval = 1
    static let highLoadThreshold = 0.85
    static let recoveredLoadThreshold = 0.60
    static let highSamplesRequired = 3
    static let recoveredSamplesRequired = 6
}

enum SystemPowerSource: Equatable, Sendable {
    case ac
    case battery
    case ups
    case unknown
}

enum SystemBatteryWarning: Equatable, Sendable {
    case none
    case early
    case final
    case unknown
}

struct SystemPowerSnapshot: Equatable, Sendable {
    let source: SystemPowerSource
    let hasInternalBattery: Bool?
    let batteryWarning: SystemBatteryWarning

    static let unknown = SystemPowerSnapshot(
        source: .unknown,
        hasInternalBattery: nil,
        batteryWarning: .unknown
    )
}

enum DisplaySleepPolicy {
    static func shouldSuspend(
        displayIDs: [CGDirectDisplayID],
        isAsleep: (CGDirectDisplayID) -> Bool
    ) -> Bool {
        displayIDs.allSatisfy(isAsleep)
    }
}

enum PowerPlaybackPolicy {
    static func energyConstraints(
        for snapshot: SystemPowerSnapshot
    ) -> Set<SystemEnergyConstraintReason> {
        guard isUsingLimitedPower(snapshot.source) else {
            return []
        }

        var constraints: Set<SystemEnergyConstraintReason> = [
            .limitedPowerSource
        ]
        if snapshot.batteryWarning == .early
            || snapshot.batteryWarning == .final {
            constraints.insert(.lowBattery)
        }
        return constraints
    }

    static func shouldSuspendDesktop(
        for snapshot: SystemPowerSnapshot
    ) -> Bool {
        isUsingLimitedPower(snapshot.source)
            && snapshot.batteryWarning == .final
    }

    private static func isUsingLimitedPower(
        _ source: SystemPowerSource
    ) -> Bool {
        source == .battery || source == .ups
    }
}

enum ThermalPlaybackPolicy {
    static func shouldReduceEffects(
        for state: ProcessInfo.ThermalState
    ) -> Bool {
        state != .nominal
    }

    static func shouldSuspendDesktop(
        for state: ProcessInfo.ThermalState
    ) -> Bool {
        state == .serious || state == .critical
    }

    static func shouldSuspendEverywhere(
        for state: ProcessInfo.ThermalState
    ) -> Bool {
        state == .critical
    }
}

struct SystemLoadPressurePolicy: Equatable, Sendable {
    let highThreshold: Double
    let recoveredThreshold: Double
    let highSamplesRequired: Int
    let recoveredSamplesRequired: Int

    private(set) var isConstrained = false
    private var consecutiveHighSamples = 0
    private var consecutiveRecoveredSamples = 0

    init(
        highThreshold: Double = SystemEnergyMonitoringPolicy.highLoadThreshold,
        recoveredThreshold: Double =
            SystemEnergyMonitoringPolicy.recoveredLoadThreshold,
        highSamplesRequired: Int =
            SystemEnergyMonitoringPolicy.highSamplesRequired,
        recoveredSamplesRequired: Int =
            SystemEnergyMonitoringPolicy.recoveredSamplesRequired
    ) {
        precondition(highThreshold > recoveredThreshold)
        precondition(highSamplesRequired > 0)
        precondition(recoveredSamplesRequired > 0)
        self.highThreshold = highThreshold
        self.recoveredThreshold = recoveredThreshold
        self.highSamplesRequired = highSamplesRequired
        self.recoveredSamplesRequired = recoveredSamplesRequired
    }

    mutating func update(normalizedLoad: Double?) -> Bool {
        guard let normalizedLoad,
              normalizedLoad.isFinite,
              normalizedLoad >= 0 else {
            reset()
            return false
        }

        if normalizedLoad >= highThreshold {
            consecutiveRecoveredSamples = 0
            guard !isConstrained else {
                return true
            }
            consecutiveHighSamples += 1
            if consecutiveHighSamples >= highSamplesRequired {
                isConstrained = true
                consecutiveHighSamples = 0
            }
            return isConstrained
        }

        if normalizedLoad <= recoveredThreshold {
            consecutiveHighSamples = 0
            guard isConstrained else {
                return false
            }
            consecutiveRecoveredSamples += 1
            if consecutiveRecoveredSamples >= recoveredSamplesRequired {
                isConstrained = false
                consecutiveRecoveredSamples = 0
            }
            return isConstrained
        }

        consecutiveHighSamples = 0
        consecutiveRecoveredSamples = 0
        return isConstrained
    }

    mutating func reset() {
        isConstrained = false
        consecutiveHighSamples = 0
        consecutiveRecoveredSamples = 0
    }
}

private enum SystemPowerSnapshotProvider {
    static func current() -> SystemPowerSnapshot {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return .unknown
        }
        let info = unmanagedInfo.takeRetainedValue()
        let source = currentSource(from: info)

        guard let unmanagedList = IOPSCopyPowerSourcesList(info) else {
            return SystemPowerSnapshot(
                source: source,
                hasInternalBattery: nil,
                batteryWarning: currentBatteryWarning()
            )
        }

        let powerSources = unmanagedList.takeRetainedValue() as [AnyObject]
        var didReadEveryDescription = true
        var hasInternalBattery = false
        for powerSource in powerSources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(
                info,
                powerSource
            ) else {
                didReadEveryDescription = false
                continue
            }
            let description = unmanagedDescription.takeUnretainedValue()
                as NSDictionary
            let type = description[kIOPSTypeKey] as? String
            let isPresent = description[kIOPSIsPresentKey] as? Bool ?? true
            if type == kIOPSInternalBatteryType && isPresent {
                hasInternalBattery = true
                break
            }
        }

        return SystemPowerSnapshot(
            source: source,
            hasInternalBattery: hasInternalBattery
                ? true
                : (didReadEveryDescription ? false : nil),
            batteryWarning: currentBatteryWarning()
        )
    }

    private static func currentSource(_ value: String) -> SystemPowerSource {
        switch value {
        case kIOPMACPowerKey:
            .ac
        case kIOPMBatteryPowerKey:
            .battery
        case kIOPMUPSPowerKey:
            .ups
        default:
            .unknown
        }
    }

    private static func currentSource(from info: AnyObject) -> SystemPowerSource {
        guard let unmanagedValue = IOPSGetProvidingPowerSourceType(info) else {
            return .unknown
        }
        let value = unmanagedValue.takeUnretainedValue() as String
        return currentSource(value)
    }

    private static func currentBatteryWarning() -> SystemBatteryWarning {
        switch IOPSGetBatteryWarningLevel() {
        case kIOPSLowBatteryWarningNone:
            .none
        case kIOPSLowBatteryWarningEarly:
            .early
        case kIOPSLowBatteryWarningFinal:
            .final
        default:
            .unknown
        }
    }
}

private enum SystemLoadSnapshotProvider {
    static func normalizedOneMinuteLoad() -> Double? {
        var loadAverage = 0.0
        guard getloadavg(&loadAverage, 1) == 1,
              loadAverage.isFinite,
              loadAverage >= 0 else {
            return nil
        }
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        guard processorCount > 0 else {
            return nil
        }
        return loadAverage / Double(processorCount)
    }
}

@MainActor
protocol SystemLoadSampling: AnyObject {
    func start(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    )
    func stop()
}

@MainActor
final class RunLoopSystemLoadSampler: NSObject, SystemLoadSampling {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    func start(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        stop()
        self.action = action
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = tolerance
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    @objc
    private func timerDidFire() {
        action?()
    }

    isolated deinit {
        timer?.invalidate()
    }
}

private final class PowerSourceCallbackContext: @unchecked Sendable {
    let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}

@MainActor
final class SystemLifecycleMonitor: SystemLifecycleMonitoring {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)?
    var energyConstraintsHandler: (
        (Set<SystemEnergyConstraintReason>) -> Void
    )?

    private let workspaceCenter: NotificationCenter
    private let defaultCenter: NotificationCenter
    private let thermalStateProvider: () -> ProcessInfo.ThermalState
    private let lowPowerModeProvider: () -> Bool
    private let powerSnapshotProvider: () -> SystemPowerSnapshot
    private let normalizedLoadProvider: () -> Double?
    private let observesPowerSourceChanges: Bool
    private let loadSampleInterval: TimeInterval
    private let loadSampler: any SystemLoadSampling
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSourceCallbackContext:
        Unmanaged<PowerSourceCallbackContext>?
    private var lowBatteryNotificationToken: Int32?
    private var loadPressurePolicy = SystemLoadPressurePolicy()
    private var activeEnergyConstraints: Set<SystemEnergyConstraintReason> = []
    private var lastPublishedEnergyConstraints:
        Set<SystemEnergyConstraintReason>?
    private var lastPublishedLowBatterySuspension: Bool?
    private var isDesktopMonitoringActive = false
    private var isLoadSampling = false
    private var loadSamplingGeneration: UInt64 = 0
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
        },
        powerSnapshotProvider: @escaping () -> SystemPowerSnapshot = {
            SystemPowerSnapshotProvider.current()
        },
        normalizedLoadProvider: @escaping () -> Double? = {
            SystemLoadSnapshotProvider.normalizedOneMinuteLoad()
        },
        observesPowerSourceChanges: Bool = true,
        loadSampleInterval: TimeInterval =
            SystemEnergyMonitoringPolicy.loadSampleInterval,
        loadSampler: any SystemLoadSampling = RunLoopSystemLoadSampler()
    ) {
        self.workspaceCenter = workspaceCenter
        self.defaultCenter = defaultCenter
        self.thermalStateProvider = thermalStateProvider
        self.lowPowerModeProvider = lowPowerModeProvider
        self.powerSnapshotProvider = powerSnapshotProvider
        self.normalizedLoadProvider = normalizedLoadProvider
        self.observesPowerSourceChanges = observesPowerSourceChanges
        precondition(loadSampleInterval > 0)
        self.loadSampleInterval = loadSampleInterval
        self.loadSampler = loadSampler
    }

    isolated deinit {
        removeRuntimeObservers()
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
        observePowerStateRefresh(
            workspaceCenter,
            name: NSWorkspace.didWakeNotification
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
                self?.publishCurrentLowPowerMode()
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

        installPowerSourceObserverIfNeeded()
        publishInitialSessionState()
        publishInitialDisplayState()
        publishCurrentThermalState(publishEnergyConstraints: false)
        publishCurrentLowPowerMode(publishEnergyConstraints: false)
        publishCurrentPowerSource(publishEnergyConstraints: false)
        publishEnergyConstraintsIfNeeded()
        updateLoadSampling()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false

        removeRuntimeObservers()
        loadPressurePolicy.reset()
        activeEnergyConstraints.removeAll()
        lastPublishedEnergyConstraints = nil
        lastPublishedLowBatterySuspension = nil
    }

    func setDesktopMonitoringActive(_ isActive: Bool) {
        guard isDesktopMonitoringActive != isActive else {
            return
        }
        isDesktopMonitoringActive = isActive
        if isActive, isRunning {
            publishCurrentPowerSource()
        }
        updateLoadSampling()
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
                guard self?.isRunning == true else {
                    return
                }
                self?.suspensionHandler?(reason, suspended)
            }
        }
        workspaceObservers.append(observer)
    }

    private func observePowerStateRefresh(
        _ center: NotificationCenter,
        name: Notification.Name
    ) {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentPowerSource()
            }
        }
        workspaceObservers.append(observer)
    }

    private func publishCurrentThermalState(
        publishEnergyConstraints: Bool = true
    ) {
        guard isRunning else {
            return
        }
        let state = thermalStateProvider()
        updateEnergyConstraint(
            .thermalPressure,
            isActive: ThermalPlaybackPolicy.shouldReduceEffects(for: state)
        )
        suspensionHandler?(
            .desktopThermalPressure,
            ThermalPlaybackPolicy.shouldSuspendDesktop(for: state)
        )
        suspensionHandler?(
            .thermalPressure,
            ThermalPlaybackPolicy.shouldSuspendEverywhere(for: state)
        )
        if publishEnergyConstraints {
            publishEnergyConstraintsIfNeeded()
        }
    }

    private func publishCurrentLowPowerMode(
        publishEnergyConstraints: Bool = true
    ) {
        guard isRunning else {
            return
        }
        updateEnergyConstraint(
            .lowPowerMode,
            isActive: lowPowerModeProvider()
        )
        if publishEnergyConstraints {
            publishEnergyConstraintsIfNeeded()
        }
    }

    private func publishCurrentPowerSource(
        publishEnergyConstraints: Bool = true
    ) {
        guard isRunning else {
            return
        }
        let snapshot = powerSnapshotProvider()
        let powerConstraints = PowerPlaybackPolicy.energyConstraints(
            for: snapshot
        )
        updateEnergyConstraint(
            .limitedPowerSource,
            isActive: powerConstraints.contains(.limitedPowerSource)
        )
        updateEnergyConstraint(
            .lowBattery,
            isActive: powerConstraints.contains(.lowBattery)
        )
        let shouldSuspendDesktop = PowerPlaybackPolicy.shouldSuspendDesktop(
            for: snapshot
        )
        if lastPublishedLowBatterySuspension != shouldSuspendDesktop {
            lastPublishedLowBatterySuspension = shouldSuspendDesktop
            suspensionHandler?(.lowBattery, shouldSuspendDesktop)
        }
        if publishEnergyConstraints {
            publishEnergyConstraintsIfNeeded()
        }
    }

    private func publishCurrentLoadPressure(generation: UInt64) {
        guard isRunning,
              isDesktopMonitoringActive,
              loadSamplingGeneration == generation else {
            return
        }
        let isConstrained = loadPressurePolicy.update(
            normalizedLoad: normalizedLoadProvider()
        )
        updateEnergyConstraint(
            .sustainedSystemLoad,
            isActive: isConstrained
        )
        publishEnergyConstraintsIfNeeded()
    }

    private func updateEnergyConstraint(
        _ reason: SystemEnergyConstraintReason,
        isActive: Bool
    ) {
        if isActive {
            activeEnergyConstraints.insert(reason)
        } else {
            activeEnergyConstraints.remove(reason)
        }
    }

    private func publishEnergyConstraintsIfNeeded() {
        guard lastPublishedEnergyConstraints != activeEnergyConstraints else {
            return
        }
        lastPublishedEnergyConstraints = activeEnergyConstraints
        energyConstraintsHandler?(activeEnergyConstraints)
    }

    private func updateLoadSampling() {
        guard isRunning, isDesktopMonitoringActive else {
            stopLoadSampling()
            loadPressurePolicy.reset()
            updateEnergyConstraint(.sustainedSystemLoad, isActive: false)
            if isRunning {
                publishEnergyConstraintsIfNeeded()
            }
            return
        }
        guard !isLoadSampling else {
            return
        }
        loadSamplingGeneration &+= 1
        let generation = loadSamplingGeneration
        isLoadSampling = true
        loadSampler.start(
            interval: loadSampleInterval,
            tolerance: min(
                SystemEnergyMonitoringPolicy.loadTimerTolerance,
                loadSampleInterval / 2
            )
        ) { [weak self] in
            self?.publishCurrentLoadPressure(generation: generation)
        }
    }

    private func stopLoadSampling() {
        loadSamplingGeneration &+= 1
        isLoadSampling = false
        loadSampler.stop()
    }

    private func installPowerSourceObserverIfNeeded() {
        guard observesPowerSourceChanges else {
            return
        }

        installLimitedPowerSourceObserverIfNeeded()
        installLowBatteryObserverIfNeeded()
    }

    private func installLimitedPowerSourceObserverIfNeeded() {
        guard powerSourceRunLoopSource == nil else {
            return
        }

        let context = PowerSourceCallbackContext { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishCurrentPowerSource()
            }
        }
        let retainedContext = Unmanaged.passRetained(context)
        guard let unmanagedSource = IOPSCreateLimitedPowerNotification(
            { rawContext in
                guard let rawContext else {
                    return
                }
                let context = Unmanaged<PowerSourceCallbackContext>
                    .fromOpaque(rawContext)
                    .takeUnretainedValue()
                context.callback()
            },
            retainedContext.toOpaque()
        ) else {
            retainedContext.release()
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        powerSourceCallbackContext = retainedContext
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func installLowBatteryObserverIfNeeded() {
        guard lowBatteryNotificationToken == nil else {
            return
        }
        var token = NOTIFY_TOKEN_INVALID
        let status = kIOPSNotifyLowBattery.withCString { name in
            notify_register_dispatch(name, &token, .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.publishCurrentPowerSource()
                }
            }
        }
        guard status == NOTIFY_STATUS_OK,
              token != NOTIFY_TOKEN_INVALID else {
            return
        }
        lowBatteryNotificationToken = token
    }

    private func removePowerSourceObserver() {
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                powerSourceRunLoopSource,
                .commonModes
            )
            self.powerSourceRunLoopSource = nil
        }
        powerSourceCallbackContext?.release()
        powerSourceCallbackContext = nil
        if let lowBatteryNotificationToken {
            notify_cancel(lowBatteryNotificationToken)
            self.lowBatteryNotificationToken = nil
        }
    }

    private func removeRuntimeObservers() {
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()

        defaultObservers.forEach(defaultCenter.removeObserver)
        defaultObservers.removeAll()

        stopLoadSampling()
        removePowerSourceObserver()
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
        guard isRunning else {
            return
        }
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
