import AppKit
import CoreServices

enum ApplicationLaunchSource: Equatable, Sendable {
    case interactive
    case loginItem
}

struct MacApplicationLaunchSourceDetector {
    func detect(
        event: NSAppleEventDescriptor?
    ) -> ApplicationLaunchSource {
        guard event?.eventClass == kCoreEventClass,
              event?.eventID == kAEOpenApplication else {
            return .interactive
        }

        // Launch Services carries the login-item marker as the pass-through
        // enum in `keyAEPropData` on the open-application event.
        let passThroughCode = event?
            .paramDescriptor(forKeyword: keyAEPropData)?
            .enumCodeValue
        return passThroughCode == keyAELaunchedAsLogInItem
            ? .loginItem
            : .interactive
    }
}

struct MacHostedUnitTestDetector {
    private static let hostedUnitTestBundleIdentifier =
        "com.muralume.MuralumeTests"
    private static let hostedUnitTestBundleName = "MuralumeTests.xctest"
    private static let testBundlePathEnvironmentKey = "XCTestBundlePath"
    private static let testSessionEnvironmentKey = "XCTestSessionIdentifier"

    func detect(
        loadedBundleIdentifiers: [String] = Bundle.allBundles.compactMap(
            \.bundleIdentifier
        ),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if loadedBundleIdentifiers.contains(
            Self.hostedUnitTestBundleIdentifier
        ) {
            return true
        }

        guard let testBundlePath = environment[
            Self.testBundlePathEnvironmentKey
        ],
        URL(fileURLWithPath: testBundlePath).lastPathComponent ==
            Self.hostedUnitTestBundleName,
        environment[Self.testSessionEnvironmentKey]?.isEmpty == false else {
            return false
        }
        return true
    }
}

@MainActor
protocol AppLifecycleCoordinating: AnyObject {
    func reopenMainWindow()
    func handleApplicationActivation(hasVisibleWindows: Bool)
    func handleCloseCommand(for window: NSWindow?) -> Bool
    func shutdown() async
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: (any AppLifecycleCoordinating)?

    private let allowsRuntimeCreation: Bool
    private var runtime: MacApplicationRuntime?
    private var terminationTask: Task<Void, Never>?
    private var didReplyToTermination = false
    private let launchSourceDetector = MacApplicationLaunchSourceDetector()

    init(allowsRuntimeCreation: Bool = true) {
        self.allowsRuntimeCreation = allowsRuntimeCreation
        super.init()
    }

    func prepareForRun(_ application: NSApplication) {
        guard allowsRuntimeCreation, runtime == nil else {
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
        guard allowsRuntimeCreation else {
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        if runtime == nil {
            prepareForRun(NSApp)
        }
        let launchSource = launchSourceDetector.detect(
            event: NSAppleEventManager.shared().currentAppleEvent
        )
        let activationPolicy: NSApplication.ActivationPolicy =
            launchSource == .loginItem ? .accessory : .regular
        if !NSApp.setActivationPolicy(activationPolicy) {
            _ = NSApp.setActivationPolicy(.regular)
            runtime?.launch(source: .interactive)
            return
        }
        runtime?.launch(source: launchSource)
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
        coordinator?.handleApplicationActivation(
            hasVisibleWindows: hasVisibleWindows
        )
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        runtime?.applicationDockMenu
    }

    private func finishTermination(for application: NSApplication) {
        guard !didReplyToTermination else {
            return
        }
        didReplyToTermination = true
        terminationTask = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}
