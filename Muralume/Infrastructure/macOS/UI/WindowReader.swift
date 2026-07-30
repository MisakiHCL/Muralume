import AppKit
import SwiftUI

@MainActor
private final class PointerActivityProbeView: NSView {
    var activityHandler: (() -> Void)?

    private weak var monitoredWindow: NSWindow?
    private var localEventMonitor: Any?
    private var previousAcceptsMouseMovedEvents: Bool?

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

    private func startMonitoring(_ window: NSWindow) {
        monitoredWindow = window
        previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .scrollWheel
            ]
        ) { [weak self, weak window] event in
            guard event.window === window else {
                return event
            }
            self?.activityHandler?()
            return event
        }
    }
}

struct PointerActivityReader: NSViewRepresentable {
    let onActivity: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PointerActivityProbeView()
        view.activityHandler = onActivity
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PointerActivityProbeView else {
            return
        }
        view.activityHandler = onActivity
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
