@MainActor
protocol SystemLifecycleMonitoring: AnyObject {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)? { get set }
    var energyConstrainedHandler: ((Bool) -> Void)? { get set }

    func start()
    func stop()
}
