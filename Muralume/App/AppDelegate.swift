import AppKit

@MainActor
protocol AppLifecycleCoordinating: AnyObject {
    func reopenMainWindow()
    func handleCloseCommand(for window: NSWindow?) -> Bool
    func shutdown() async
}

@MainActor
final class MacMainMenuController: NSObject {
    private enum MainMenuPosition {
        static let applicationMenuIndex = 0
        static let customMenuCountBeforeWindow = 1
    }

    weak var lifecycleCoordinator: (any AppLifecycleCoordinating)?
    private weak var application: NSApplication?
    private var isObservingMenuChanges = false
    private var isRefreshScheduled = false

    func start(for application: NSApplication) {
        self.application = application
        if !isObservingMenuChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidAddItem),
                name: NSMenu.didAddItemNotification,
                object: nil
            )
            isObservingMenuChanges = true
        }

        routeCloseCommand(in: application.windowsMenu)
        guard let mainMenu = application.mainMenu else {
            return
        }
        removeRedundantTopLevelMenus(
            from: mainMenu,
            windowsMenu: application.windowsMenu
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        application = nil
        isObservingMenuChanges = false
        isRefreshScheduled = false
    }

    func removeRedundantTopLevelMenus(
        from mainMenu: NSMenu,
        windowsMenu: NSMenu?
    ) {
        guard
            let windowsMenu,
            let windowMenuIndex = mainMenu.items.firstIndex(
                where: { $0.submenu === windowsMenu }
            )
        else {
            return
        }

        let customMenuIndex =
            windowMenuIndex - MainMenuPosition.customMenuCountBeforeWindow
        let firstRedundantMenuIndex =
            MainMenuPosition.applicationMenuIndex + 1
        guard customMenuIndex > firstRedundantMenuIndex else {
            return
        }

        let redundantItems = Array(
            mainMenu.items[firstRedundantMenuIndex..<customMenuIndex]
        )
        redundantItems.forEach(mainMenu.removeItem)
    }

    @objc
    private func menuDidAddItem(_ notification: Notification) {
        if let changedMenu = notification.object as? NSMenu,
           changedMenu === application?.windowsMenu {
            routeCloseCommand(in: changedMenu)
        }
        guard !isRefreshScheduled else {
            return
        }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            isRefreshScheduled = false
            guard let application else {
                return
            }
            start(for: application)
        }
    }

    private func routeCloseCommand(in windowsMenu: NSMenu?) {
        guard let windowsMenu else {
            return
        }
        for item in windowsMenu.items
        where item.action == #selector(NSWindow.performClose(_:)) {
            item.target = self
            item.action = #selector(handleCloseCommand(_:))
        }
    }

    @objc
    private func handleCloseCommand(_ sender: Any?) {
        guard let window = application?.keyWindow else {
            return
        }
        if lifecycleCoordinator?.handleCloseCommand(for: window) == true {
            return
        }
        window.performClose(sender)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationPolicy {
        static let cleanupTimeout: Duration = .seconds(2)
    }

    var coordinator: (any AppLifecycleCoordinating)? {
        didSet {
            mainMenuController.lifecycleCoordinator = coordinator
        }
    }
    private let mainMenuController = MacMainMenuController()
    private var terminationTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var didReplyToTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenuController.start(for: NSApp)
        DispatchQueue.main.async { [weak self] in
            self?.mainMenuController.start(for: NSApp)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainMenuController.start(for: NSApp)
        restoreMainWindowAfterActivationIfNeeded(
            hasVisibleWindows: NSApp.windows.contains(where: \.isVisible)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainMenuController.stop()
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
