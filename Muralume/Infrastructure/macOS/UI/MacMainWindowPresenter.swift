import AppKit

private enum MainWindowNotification {
    static let chromeChanges: [Notification.Name] = [
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification
    ]
    static let miniaturizationChanges: [Notification.Name] = [
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification
    ]
}

@MainActor
final class MacMainWindowPresenter: NSObject, MainWindowPresenting {
    var unexpectedWindowCloseHandler: (() -> Void)?
    var miniaturizationStateHandler: ((Bool) -> Void)? {
        didSet {
            if let window {
                publishMiniaturizationState(
                    window.isMiniaturized,
                    force: true
                )
            }
        }
    }
    var fullScreenStateHandler: ((Bool) -> Void)? {
        didSet {
            if let window {
                publishFullScreenState(
                    window.styleMask.contains(.fullScreen),
                    force: true
                )
            }
        }
    }

    private var window: NSWindow?
    private var lastPublishedMiniaturizationState: Bool?
    private var lastPublishedFullScreenState: Bool?
    private var isDismissalPending = false
    private var hasObservedUnexpectedClose = false

    override init() {
        super.init()
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else {
            return
        }
        if let currentWindow = self.window {
            currentWindow.orderOut(nil)
            stopObserving(currentWindow)
        }

        self.window = window
        window.isReleasedWhenClosed = false
        lastPublishedMiniaturizationState = nil
        lastPublishedFullScreenState = nil
        isDismissalPending = false
        hasObservedUnexpectedClose = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        for notificationName in MainWindowNotification.chromeChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChromeDidChange(_:)),
                name: notificationName,
                object: window
            )
        }
        for notificationName in MainWindowNotification.miniaturizationChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowMiniaturizationDidChange(_:)),
                name: notificationName,
                object: window
            )
        }
        applyWindowChrome(to: window)
        window.minSize = NSSize(
            width: AppConfiguration.minimumWindowWidth,
            height: AppConfiguration.minimumWindowHeight
        )
        publishFullScreenState(
            window.styleMask.contains(.fullScreen),
            force: true
        )
        publishMiniaturizationState(window.isMiniaturized, force: true)
    }

    private func applyWindowChrome(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.toolbar?.showsBaselineSeparator = false
        window.toolbar = nil
        hideSystemWindowControls(in: window)
    }

    func hide() {
        isDismissalPending = false
        window?.orderOut(nil)
    }

    func prepareForReturn() {
        isDismissalPending = false
        window?.alphaValue = 0.01
        window?.orderBack(nil)
    }

    func show() {
        guard let window else {
            return
        }
        isDismissalPending = false
        hasObservedUnexpectedClose = false
        window.alphaValue = 1
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideAfterFailedReturn() {
        isDismissalPending = false
        window?.orderOut(nil)
        window?.alphaValue = 1
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func dismiss() {
        guard let window, !isDismissalPending else {
            return
        }
        guard window.styleMask.contains(.fullScreen) else {
            window.orderOut(nil)
            return
        }

        isDismissalPending = true
        window.toggleFullScreen(nil)
    }

    func minimize() {
        window?.miniaturize(nil)
    }

    func isPresenting(_ candidate: NSWindow?) -> Bool {
        guard let candidate, let window else {
            return false
        }
        return candidate === window
    }

    @objc
    private func mainWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window,
              !hasObservedUnexpectedClose else {
            return
        }

        hasObservedUnexpectedClose = true
        isDismissalPending = false
        publishFullScreenState(false)
        publishMiniaturizationState(false)
        unexpectedWindowCloseHandler?()
    }

    @objc
    private func windowMiniaturizationDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }

        if notification.name == NSWindow.didMiniaturizeNotification {
            publishMiniaturizationState(true)
        } else if notification.name == NSWindow.didDeminiaturizeNotification {
            publishMiniaturizationState(false)
        }
    }

    @objc
    private func windowChromeDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }

        hideSystemWindowControls(in: changedWindow)
        if notification.name == NSWindow.didEnterFullScreenNotification {
            publishFullScreenState(true)
        } else if notification.name == NSWindow.didExitFullScreenNotification {
            publishFullScreenState(false)
            if isDismissalPending {
                isDismissalPending = false
                changedWindow.orderOut(nil)
            }
        }
    }

    private func hideSystemWindowControls(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        for button in buttons {
            button.isHidden = true
        }
    }

    private func publishFullScreenState(
        _ isFullScreen: Bool,
        force: Bool = false
    ) {
        guard force || lastPublishedFullScreenState != isFullScreen else {
            return
        }
        lastPublishedFullScreenState = isFullScreen
        fullScreenStateHandler?(isFullScreen)
    }

    private func publishMiniaturizationState(
        _ isMiniaturized: Bool,
        force: Bool = false
    ) {
        guard force
                || lastPublishedMiniaturizationState != isMiniaturized else {
            return
        }
        lastPublishedMiniaturizationState = isMiniaturized
        miniaturizationStateHandler?(isMiniaturized)
    }

    private func stopObserving(_ window: NSWindow) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        for notificationName in MainWindowNotification.chromeChanges {
            NotificationCenter.default.removeObserver(
                self,
                name: notificationName,
                object: window
            )
        }
        for notificationName in MainWindowNotification.miniaturizationChanges {
            NotificationCenter.default.removeObserver(
                self,
                name: notificationName,
                object: window
            )
        }
    }
}
