import AppKit
import XCTest
@testable import Muralume

@MainActor
final class SystemLifecycleMonitorTests: XCTestCase {
    private enum TestPolicy {
        static let eventPropagationAttempts = 20
    }

    func testMediaSourceRecoveryMonitorEmitsOnlyWhileStarted() async {
        let workspaceCenter = NotificationCenter()
        let monitor = MediaSourceAccessRecoveryMonitor(
            workspaceCenter: workspaceCenter
        )
        var recoveryCount = 0
        monitor.recoveryHandler = {
            recoveryCount += 1
        }

        monitor.start()
        monitor.start()
        workspaceCenter.post(
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        await waitUntil { recoveryCount == 1 }

        monitor.stop()
        workspaceCenter.post(
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        for _ in 0..<TestPolicy.eventPropagationAttempts {
            await Task.yield()
        }

        XCTAssertEqual(recoveryCount, 1)
    }

    func testPublicWorkspaceNotificationsUpdateSuspensionState() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter,
            powerSnapshotProvider: { .unknown },
            observesPowerSourceChanges: false
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

    func testThermalPolicyUsesProgressiveProtection() {
        XCTAssertFalse(
            ThermalPlaybackPolicy.shouldReduceEffects(for: .nominal)
        )
        XCTAssertTrue(
            ThermalPlaybackPolicy.shouldReduceEffects(for: .fair)
        )
        XCTAssertFalse(
            ThermalPlaybackPolicy.shouldSuspendDesktop(for: .fair)
        )
        XCTAssertTrue(
            ThermalPlaybackPolicy.shouldSuspendDesktop(for: .serious)
        )
        XCTAssertFalse(
            ThermalPlaybackPolicy.shouldSuspendEverywhere(for: .serious)
        )
        XCTAssertTrue(
            ThermalPlaybackPolicy.shouldSuspendEverywhere(for: .critical)
        )
    }

    func testThermalNotificationPublishesInjectedCurrentState() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        var thermalState = ProcessInfo.ThermalState.nominal
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter,
            thermalStateProvider: { thermalState },
            powerSnapshotProvider: { .unknown },
            observesPowerSourceChanges: false
        )
        var thermalSuspensions: [Bool] = []
        monitor.suspensionHandler = { reason, isSuspended in
            guard reason == .desktopThermalPressure else {
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
            thermalStateProvider: { .nominal },
            lowPowerModeProvider: { isLowPowerModeEnabled },
            powerSnapshotProvider: { .unknown },
            observesPowerSourceChanges: false
        )
        var suspensionEvents: [(PlaybackSuspensionReason, Bool)] = []
        var energyConstraints: [Set<SystemEnergyConstraintReason>] = []
        monitor.suspensionHandler = { reason, isSuspended in
            suspensionEvents.append((reason, isSuspended))
        }
        monitor.energyConstraintsHandler = {
            energyConstraints.append($0)
        }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(energyConstraints, [[]])
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
        XCTAssertEqual(energyConstraints, [[.lowPowerMode]])
        XCTAssertTrue(suspensionEvents.isEmpty)
    }

    func testPowerPolicyTreatsMissingBatteryOnACAsUnconstrained() {
        let snapshot = SystemPowerSnapshot(
            source: .ac,
            hasInternalBattery: false,
            batteryWarning: .none
        )

        XCTAssertTrue(
            PowerPlaybackPolicy.energyConstraints(for: snapshot).isEmpty
        )
        XCTAssertFalse(
            PowerPlaybackPolicy.shouldSuspendDesktop(for: snapshot)
        )
    }

    func testPowerPolicyReducesEffectsOnBatteryAndSuspendsOnlyAtFinalWarning() {
        let early = SystemPowerSnapshot(
            source: .battery,
            hasInternalBattery: true,
            batteryWarning: .early
        )
        let final = SystemPowerSnapshot(
            source: .battery,
            hasInternalBattery: true,
            batteryWarning: .final
        )

        XCTAssertEqual(
            PowerPlaybackPolicy.energyConstraints(for: early),
            [.limitedPowerSource, .lowBattery]
        )
        XCTAssertFalse(
            PowerPlaybackPolicy.shouldSuspendDesktop(for: early)
        )
        XCTAssertTrue(
            PowerPlaybackPolicy.shouldSuspendDesktop(for: final)
        )
    }

    func testUnknownPowerStateFailsOpen() {
        XCTAssertTrue(
            PowerPlaybackPolicy.energyConstraints(for: .unknown).isEmpty
        )
        XCTAssertFalse(
            PowerPlaybackPolicy.shouldSuspendDesktop(for: .unknown)
        )
    }

    func testLoadPressureRequiresSustainedHighAndRecoveredSamples() {
        var policy = SystemLoadPressurePolicy(
            highThreshold: 0.85,
            recoveredThreshold: 0.60,
            highSamplesRequired: 3,
            recoveredSamplesRequired: 2
        )

        XCTAssertFalse(policy.update(normalizedLoad: 0.85))
        XCTAssertFalse(policy.update(normalizedLoad: 0.90))
        XCTAssertTrue(policy.update(normalizedLoad: 1.20))
        XCTAssertTrue(policy.update(normalizedLoad: 0.70))
        XCTAssertTrue(policy.update(normalizedLoad: 0.60))
        XCTAssertFalse(policy.update(normalizedLoad: 0.40))
    }

    func testDefaultLoadPressurePolicyUsesConfiguredHysteresis() {
        var policy = SystemLoadPressurePolicy()

        for _ in 1..<SystemEnergyMonitoringPolicy.highSamplesRequired {
            XCTAssertFalse(policy.update(normalizedLoad: 1))
        }
        XCTAssertTrue(policy.update(normalizedLoad: 1))

        for _ in 1..<SystemEnergyMonitoringPolicy.recoveredSamplesRequired {
            XCTAssertTrue(policy.update(normalizedLoad: 0))
        }
        XCTAssertFalse(policy.update(normalizedLoad: 0))
    }

    func testInvalidLoadSampleFailsOpenAndResetsDebounce() {
        var policy = SystemLoadPressurePolicy(
            highThreshold: 0.85,
            recoveredThreshold: 0.60,
            highSamplesRequired: 2,
            recoveredSamplesRequired: 2
        )

        XCTAssertFalse(policy.update(normalizedLoad: 1))
        XCTAssertFalse(policy.update(normalizedLoad: .nan))
        XCTAssertFalse(policy.update(normalizedLoad: 1))
        XCTAssertTrue(policy.update(normalizedLoad: 1))
        XCTAssertFalse(policy.update(normalizedLoad: nil))
    }

    func testLoadPressureDebounceRequiresConsecutiveBoundarySamples() {
        var policy = SystemLoadPressurePolicy(
            highThreshold: 0.85,
            recoveredThreshold: 0.60,
            highSamplesRequired: 2,
            recoveredSamplesRequired: 2
        )

        XCTAssertFalse(policy.update(normalizedLoad: 1))
        XCTAssertFalse(policy.update(normalizedLoad: 0.70))
        XCTAssertFalse(policy.update(normalizedLoad: 1))
        XCTAssertTrue(policy.update(normalizedLoad: 1))

        XCTAssertTrue(policy.update(normalizedLoad: 0.50))
        XCTAssertTrue(policy.update(normalizedLoad: 0.70))
        XCTAssertTrue(policy.update(normalizedLoad: 0.50))
        XCTAssertFalse(policy.update(normalizedLoad: 0.50))
    }

    func testEnergyConstraintReasonsUnwindIndependently() async {
        let workspaceCenter = NotificationCenter()
        let defaultCenter = NotificationCenter()
        var thermalState = ProcessInfo.ThermalState.fair
        var isLowPowerModeEnabled = true
        var powerSnapshot = SystemPowerSnapshot(
            source: .battery,
            hasInternalBattery: true,
            batteryWarning: .early
        )
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: workspaceCenter,
            defaultCenter: defaultCenter,
            thermalStateProvider: { thermalState },
            lowPowerModeProvider: { isLowPowerModeEnabled },
            powerSnapshotProvider: { powerSnapshot },
            observesPowerSourceChanges: false,
            loadSampler: ControlledSystemLoadSampler()
        )
        var constraints: [Set<SystemEnergyConstraintReason>] = []
        monitor.energyConstraintsHandler = { constraints.append($0) }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(
            constraints.last,
            [
                .limitedPowerSource,
                .lowBattery,
                .lowPowerMode,
                .thermalPressure
            ]
        )

        powerSnapshot = SystemPowerSnapshot(
            source: .ac,
            hasInternalBattery: true,
            batteryWarning: .none
        )
        monitor.setDesktopMonitoringActive(true)
        XCTAssertEqual(
            constraints.last,
            [.lowPowerMode, .thermalPressure]
        )

        isLowPowerModeEnabled = false
        defaultCenter.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo
        )
        await waitUntil {
            constraints.last?.contains(.lowPowerMode) == false
        }
        XCTAssertEqual(
            constraints.last,
            [.thermalPressure]
        )

        thermalState = .nominal
        defaultCenter.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo
        )
        await waitUntil {
            constraints.last?.contains(.thermalPressure) == false
        }
        XCTAssertEqual(constraints.last, [])
    }

    func testStoppedMonitorDropsQueuedScreenParameterRefresh() async {
        let defaultCenter = NotificationCenter()
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: NotificationCenter(),
            defaultCenter: defaultCenter,
            powerSnapshotProvider: { .unknown },
            observesPowerSourceChanges: false
        )
        var events: [PlaybackSuspensionReason] = []
        monitor.suspensionHandler = { reason, _ in events.append(reason) }
        monitor.start()
        events.removeAll()

        defaultCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        monitor.stop()
        for _ in 0..<TestPolicy.eventPropagationAttempts {
            await Task.yield()
        }

        XCTAssertTrue(events.isEmpty)
    }

    func testLoadSamplerRejectsCallbacksFromPreviousActivation() {
        let sampler = ControlledSystemLoadSampler()
        var loadProviderCallCount = 0
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: NotificationCenter(),
            defaultCenter: NotificationCenter(),
            thermalStateProvider: { .nominal },
            lowPowerModeProvider: { false },
            powerSnapshotProvider: { .unknown },
            normalizedLoadProvider: {
                loadProviderCallCount += 1
                return 1
            },
            observesPowerSourceChanges: false,
            loadSampler: sampler
        )
        var constraints: [Set<SystemEnergyConstraintReason>] = []
        monitor.energyConstraintsHandler = { constraints.append($0) }
        monitor.start()
        constraints.removeAll()

        monitor.setDesktopMonitoringActive(true)
        XCTAssertEqual(
            sampler.intervals,
            [SystemEnergyMonitoringPolicy.loadSampleInterval]
        )
        XCTAssertEqual(
            sampler.tolerances,
            [SystemEnergyMonitoringPolicy.loadTimerTolerance]
        )
        let firstAction = sampler.actions[0]
        firstAction()
        firstAction()
        XCTAssertEqual(loadProviderCallCount, 2)
        monitor.setDesktopMonitoringActive(false)
        monitor.setDesktopMonitoringActive(true)

        firstAction()
        XCTAssertEqual(loadProviderCallCount, 2)
        sampler.fireCurrent()
        sampler.fireCurrent()
        XCTAssertEqual(loadProviderCallCount, 4)
        XCTAssertTrue(constraints.isEmpty)

        sampler.fireCurrent()
        XCTAssertEqual(loadProviderCallCount, 5)
        XCTAssertEqual(constraints, [[.sustainedSystemLoad]])

        let currentAction = sampler.currentAction
        monitor.stop()
        currentAction?()
        XCTAssertEqual(loadProviderCallCount, 5)
        XCTAssertEqual(constraints, [[.sustainedSystemLoad]])
    }

    func testLeavingDesktopClearsOnlySustainedLoadConstraint() {
        let sampler = ControlledSystemLoadSampler()
        let monitor = SystemLifecycleMonitor(
            workspaceCenter: NotificationCenter(),
            defaultCenter: NotificationCenter(),
            thermalStateProvider: { .nominal },
            lowPowerModeProvider: { true },
            powerSnapshotProvider: { .unknown },
            normalizedLoadProvider: { 1 },
            observesPowerSourceChanges: false,
            loadSampler: sampler
        )
        var constraints: [Set<SystemEnergyConstraintReason>] = []
        monitor.energyConstraintsHandler = { constraints.append($0) }
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(constraints.last, [.lowPowerMode])
        monitor.setDesktopMonitoringActive(true)
        for _ in 0..<SystemEnergyMonitoringPolicy.highSamplesRequired {
            sampler.fireCurrent()
        }
        XCTAssertEqual(
            constraints.last,
            [.lowPowerMode, .sustainedSystemLoad]
        )

        monitor.setDesktopMonitoringActive(false)
        XCTAssertEqual(constraints.last, [.lowPowerMode])
    }

    func testDeinitStopsInjectedLoadSampler() {
        let sampler = ControlledSystemLoadSampler()
        var monitor: SystemLifecycleMonitor? = SystemLifecycleMonitor(
            workspaceCenter: NotificationCenter(),
            defaultCenter: NotificationCenter(),
            powerSnapshotProvider: { .unknown },
            observesPowerSourceChanges: false,
            loadSampler: sampler
        )
        monitor?.start()
        monitor?.setDesktopMonitoringActive(true)
        let stopCountBeforeRelease = sampler.stopCount

        monitor = nil

        XCTAssertGreaterThan(sampler.stopCount, stopCountBeforeRelease)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<TestPolicy.eventPropagationAttempts where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class ControlledSystemLoadSampler: SystemLoadSampling {
    private(set) var actions: [@MainActor () -> Void] = []
    private(set) var currentAction: (@MainActor () -> Void)?
    private(set) var intervals: [TimeInterval] = []
    private(set) var tolerances: [TimeInterval] = []
    private(set) var stopCount = 0

    func start(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        intervals.append(interval)
        tolerances.append(tolerance)
        currentAction = action
        actions.append(action)
    }

    func stop() {
        stopCount += 1
        currentAction = nil
    }

    func fireCurrent() {
        currentAction?()
    }
}
