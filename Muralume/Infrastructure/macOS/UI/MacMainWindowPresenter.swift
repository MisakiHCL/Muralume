import AppKit

private enum MainWindowNotification {
    static let chromeChanges: [Notification.Name] = [
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification
    ]
}

@MainActor
final class MacMainWindowPresenter: NSObject, MainWindowPresenting {
    var mainWindowCloseHandler: (() -> Void)?
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

    private weak var window: NSWindow?
    private var lastPublishedFullScreenState: Bool?

    override init() {
        super.init()
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else {
            return
        }
        if let currentWindow = self.window {
            stopObserving(currentWindow)
        }

        self.window = window
        lastPublishedFullScreenState = nil
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
        applyWindowChrome(to: window)
        window.minSize = NSSize(
            width: AppConfiguration.minimumWindowWidth,
            height: AppConfiguration.minimumWindowHeight
        )
        publishFullScreenState(
            window.styleMask.contains(.fullScreen),
            force: true
        )
    }

    private func applyWindowChrome(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MuralumeTheme.Colors.windowNSColor
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
    }

    func hide() {
        window?.orderOut(nil)
    }

    func prepareForReturn() {
        window?.alphaValue = 0.01
        window?.orderBack(nil)
    }

    func show() {
        guard let window else {
            return
        }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideAfterFailedReturn() {
        window?.orderOut(nil)
        window?.alphaValue = 1
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    @objc
    private func mainWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        stopObserving(closingWindow)
        window = nil
        publishFullScreenState(false)
        mainWindowCloseHandler?()
    }

    @objc
    private func windowChromeDidChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }
        applyWindowChrome(to: changedWindow)
        if notification.name == NSWindow.didEnterFullScreenNotification {
            publishFullScreenState(true)
        } else if notification.name == NSWindow.didExitFullScreenNotification {
            publishFullScreenState(false)
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
    }
}
