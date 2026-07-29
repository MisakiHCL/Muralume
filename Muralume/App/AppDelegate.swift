import AppKit

@MainActor
protocol AppLifecycleCoordinating: AnyObject {
    var shouldRouteReopenToDesktopSession: Bool { get }

    func returnToPlayer()
    func showMainWindow()
    func shutdown() async
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationPolicy {
        static let cleanupTimeout: Duration = .seconds(2)
    }

    weak var coordinator: (any AppLifecycleCoordinating)?
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var didReplyToTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !didReplyToTermination else {
            return .terminateNow
        }
        guard let coordinator else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { [weak self] in
            await coordinator.shutdown()
            self?.finishTermination(for: sender)
        }
        terminationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: TerminationPolicy.cleanupTimeout)
            guard !Task.isCancelled else {
                return
            }
            self?.finishTermination(for: sender)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if coordinator?.shouldRouteReopenToDesktopSession == true {
            coordinator?.returnToPlayer()
            return true
        }

        if !flag {
            coordinator?.showMainWindow()
        }
        return true
    }

    private func finishTermination(for application: NSApplication) {
        guard !didReplyToTermination else {
            return
        }
        didReplyToTermination = true
        terminationTimeoutTask?.cancel()
        terminationTask = nil
        terminationTimeoutTask = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}
