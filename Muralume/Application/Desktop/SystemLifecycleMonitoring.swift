enum SystemEnergyConstraintReason: Hashable, Sendable {
    case limitedPowerSource
    case lowBattery
    case lowPowerMode
    case sustainedSystemLoad
    case thermalPressure
}

@MainActor
protocol SystemLifecycleMonitoring: AnyObject {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)? { get set }
    var energyConstraintsHandler: (
        (Set<SystemEnergyConstraintReason>) -> Void
    )? { get set }

    func start()
    func stop()
    func setDesktopMonitoringActive(_ isActive: Bool)
}
