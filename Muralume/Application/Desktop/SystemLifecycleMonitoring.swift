@MainActor
protocol SystemLifecycleMonitoring: AnyObject {
    var suspensionHandler: ((PlaybackSuspensionReason, Bool) -> Void)? { get set }

    func start()
    func stop()
}
