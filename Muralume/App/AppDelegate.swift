import AppKit

@MainActor
protocol AppLifecycleCoordinating: AnyObject {
    func reopenMainWindow()
    func handleCloseCommand(for window: NSWindow?) -> Bool
    func shutdown() async
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationPolicy {
        static let cleanupTimeout: Duration = .seconds(2)
    }

    var coordinator: (any AppLifecycleCoordinating)?

    private var runtime: MacApplicationRuntime?
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var didReplyToTermination = false

    func prepareForRun(_ application: NSApplication) {
        guard runtime == nil else {
            return
        }

        let runtime = MacApplicationRuntime(application: application)
        self.runtime = runtime
        coordinator = runtime.coordinator
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runtime == nil {
            prepareForRun(NSApp)
        }
        runtime?.launch()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: NSApp.windows.contains(where: \.isVisible)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
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
        guard let coordinator else {
            return true
        }

        coordinator.reopenMainWindow()
        return false
    }

    func restoreMainWindowAfterActivationIfNeeded(
        hasVisibleWindows: Bool
    ) {
        guard !hasVisibleWindows else {
            return
        }
        coordinator?.reopenMainWindow()
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
