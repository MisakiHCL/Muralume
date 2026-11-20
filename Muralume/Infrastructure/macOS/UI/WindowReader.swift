import AppKit
import SwiftUI

@MainActor
private final class PointerActivityProbeView: NSView {
    var activityHandler: (() -> Void)?

    private weak var monitoredWindow: NSWindow?
    private var localEventMonitor: Any?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var hidesIdleCursor = false
    private var hidCursor = false
    private var trackingMenus: Set<ObjectIdentifier> = []

    isolated deinit {
        stopMonitoring()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitoredWindow !== window else {
            return
        }
        stopMonitoring()
        if let window {
            startMonitoring(window)
        }
    }

    func stopMonitoring() {
        restoreCursor()
        NotificationCenter.default.removeObserver(self)
        trackingMenus.removeAll()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let monitoredWindow, let previousAcceptsMouseMovedEvents {
            monitoredWindow.acceptsMouseMovedEvents =
                previousAcceptsMouseMovedEvents
        }
        monitoredWindow = nil
        previousAcceptsMouseMovedEvents = nil
    }

    func setHidesIdleCursor(_ hidesIdleCursor: Bool) {
        guard self.hidesIdleCursor != hidesIdleCursor else { return }
        self.hidesIdleCursor = hidesIdleCursor
        if hidesIdleCursor {
            hideCursorIfEligible()
        } else {
            restoreCursor()
        }
    }

    private func startMonitoring(_ window: NSWindow) {
        monitoredWindow = window
        previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        observeCursorLifecycle(in: window)

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .scrollWheel,
                .leftMouseDown,
                .rightMouseDown
            ]
        ) { [weak self, weak window] event in
            guard let window, event.window === window else {
                return event
            }
            switch event.type {
            case .leftMouseDown where !event.modifierFlags.contains(.control):
                break
            case .leftMouseDown, .rightMouseDown:
                self?.restoreCursor()
            default:
                self?.restoreCursor()
                self?.activityHandler?()
            }
            return event
        }
        hideCursorIfEligible()
    }

    private func observeCursorLifecycle(in window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(cursorEligibilityEnded(_:)), name: name, object: window)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification] {
            center.addObserver(self, selector: #selector(cursorEligibilityBegan(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(cursorEligibilityEnded(_:)),
                           name: NSApplication.willResignActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(cursorEligibilityBegan(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(menuTrackingBegan(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuTrackingEnded(_:)),
                           name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func cursorEligibilityBegan(_ notification: Notification) {
        hideCursorIfEligible()
    }

    @objc private func cursorEligibilityEnded(_ notification: Notification) {
        restoreCursor()
    }

    @objc private func menuTrackingBegan(_ notification: Notification) {
        if let menu = notification.object as? NSMenu {
            trackingMenus.insert(ObjectIdentifier(menu))
        }
        restoreCursor()
    }

    @objc private func menuTrackingEnded(_ notification: Notification) {
        if let menu = notification.object as? NSMenu {
            trackingMenus.remove(ObjectIdentifier(menu))
        }
        hideCursorIfEligible()
    }

    private func hideCursorIfEligible() {
        guard hidesIdleCursor, !hidCursor, trackingMenus.isEmpty, NSApp.isActive,
              let window = monitoredWindow, window.isKeyWindow, window.styleMask.contains(.fullScreen),
              window.contentLayoutRect.contains(window.mouseLocationOutsideOfEventStream) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        hidCursor = true
    }

    private func restoreCursor() {
        guard hidCursor else { return }
        NSCursor.setHiddenUntilMouseMoves(false)
        hidCursor = false
    }
}

struct PointerActivityReader: NSViewRepresentable {
    let hidesIdleCursor: Bool
    let onActivity: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PointerActivityProbeView()
        view.activityHandler = onActivity
        view.setHidesIdleCursor(hidesIdleCursor)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PointerActivityProbeView else {
            return
        }
        view.activityHandler = onActivity
        view.setHidesIdleCursor(hidesIdleCursor)
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: Void
    ) {
        guard let view = nsView as? PointerActivityProbeView else {
            return
        }
        view.stopMonitoring()
    }
}
