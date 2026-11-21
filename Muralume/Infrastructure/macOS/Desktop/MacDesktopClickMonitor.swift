import AppKit
import CoreGraphics

enum DesktopPointerInput {
    case click
    case movement
    case pressBegan
    case pressMoved
    case pressEnded
}

extension DesktopInteractionEffect {
    var respondsToHover: Bool { self == .hoverLens || self == .shadowLight }
    var followsHeldPointer: Bool { respondsToHover || self == .colorFocus }

    var mouseEventMask: NSEvent.EventTypeMask {
        guard self != .off else { return [] }
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                           .rightMouseDown, .otherMouseDown]
        if respondsToHover || self == .waterRipple { mask.insert(.mouseMoved) }
        return mask
    }
}

struct DesktopClickGesture {
    private struct Press {
        let location: NSPoint
        let windowID: CGWindowID
        let time: TimeInterval
    }

    private static let maximumTravel: CGFloat = 4
    private static let maximumDuration: TimeInterval = 0.8
    private var press: Press?

    var isTracking: Bool { press != nil }

    mutating func begin(at point: NSPoint, windowID: CGWindowID?, time: TimeInterval) {
        press = windowID.map { Press(location: point, windowID: $0, time: time) }
    }

    mutating func drag(to point: NSPoint) {
        if let press, !Self.isNear(point, press.location) {
            cancel()
        }
    }

    mutating func finish(at point: NSPoint, windowID: CGWindowID?, time: TimeInterval) -> CGWindowID? {
        defer { cancel() }
        guard let press, windowID == press.windowID,
              (0...Self.maximumDuration).contains(time - press.time),
              Self.isNear(point, press.location) else {
            return nil
        }
        return press.windowID
    }

    mutating func cancel() {
        press = nil
    }

    private static func isNear(_ point: NSPoint, _ origin: NSPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) <= maximumTravel
    }
}

struct DesktopMarqueeGesture {
    private struct Press {
        let point: CGPoint
        let window: CGWindowID
        let dragChangeCount: Int
        var didDrag = false
    }

    private static let minimumExtent: CGFloat = 4
    private var press: Press?
    var startingWindow: CGWindowID? { press?.window }

    mutating func begin(at point: CGPoint, desktopWindow: CGWindowID, dragChangeCount: Int) {
        press = Press(point: point, window: desktopWindow, dragChangeCount: dragChangeCount)
    }

    mutating func drag(overFileDragImage: Bool) {
        if overFileDragImage { cancel() } else { press?.didDrag = true }
    }

    mutating func finish(at point: CGPoint, window: CGWindowID?, dragChangeCount: Int) -> CGRect? {
        defer { cancel() }
        guard let press, press.didDrag, press.window == window,
              press.dragChangeCount == dragChangeCount else { return nil }
        let rect = CGRect(x: min(press.point.x, point.x), y: min(press.point.y, point.y),
                          width: abs(press.point.x - point.x), height: abs(press.point.y - point.y))
        guard rect.width >= Self.minimumExtent, rect.height >= Self.minimumExtent else { return nil }
        return rect
    }

    mutating func cancel() {
        press = nil
    }
}

/// Samples only while the pointer moves. Reuse the layer classification for
/// the window under the pointer, and recheck immediately on crossing a window.
struct DesktopPointerSampler {
    private static let interval: TimeInterval = 1.0 / 30
    private static let classificationLifetime: TimeInterval = 0.5
    private var lastSample: TimeInterval?
    private var classification: (window: CGWindowID, desktop: Bool, expiry: TimeInterval)?

    mutating func desktopHit(
        at time: TimeInterval,
        throttle: Bool = true,
        hitWindow: () -> CGWindowID?,
        isDesktopWindow: (CGWindowID) -> Bool
    ) -> Bool? {
        if throttle, let lastSample, time - lastSample < Self.interval { return nil }
        lastSample = time
        guard let id = hitWindow() else {
            classification = nil
            return false
        }
        if let classification, classification.window == id, time < classification.expiry {
            return classification.desktop
        }
        let desktop = isDesktopWindow(id)
        classification = (id, desktop, time + Self.classificationLifetime)
        return desktop
    }
}

@MainActor
final class MacDesktopClickMonitor {
    private var monitor: Any?
    private var localPointerMonitor: Any?
    private var gesture = DesktopClickGesture()
    private var marquee = DesktopMarqueeGesture()
    private var pointerSampler = DesktopPointerSampler()
    private var refreshHover: (() -> Void)?
    private var releaseWatchdog: Task<Void, Never>?

    isolated deinit {
        stop()
    }

    func start(
        for effect: DesktopInteractionEffect,
        handler: @escaping (DesktopPointerInput, NSPoint) -> Void,
        onExit: @escaping () -> Void,
        onMarquee: @escaping (CGRect) -> Void
    ) {
        let mask = effect.mouseEventMask
        guard !mask.isEmpty, monitor == nil, localPointerMonitor == nil else { return }

        let receive: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .mouseMoved:
                let input: DesktopPointerInput = releaseWatchdog == nil ? .movement : .pressMoved
                observePointer(event, throttle: !effect.respondsToHover, input: input, handler: handler, onExit: onExit)
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                switch effect {
                case .localFreeze:
                    observeMarquee(event, handler: onMarquee)
                case .hoverLens, .colorFocus, .shadowLight:
                    observePress(event, respondsToHover: effect.respondsToHover, handler: handler, onExit: onExit)
                case .waterRipple:
                    observeClick(event) { handler(.click, $0) }
                case .off:
                    break
                }
            default:
                cancelReleaseWatchdog()
                gesture.cancel()
                marquee.cancel()
                onExit()
            }
        }
        // Global monitors receive copies. The local monitor also returns each original
        // event intact, including Finder-style drags routed to a window of this app.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: receive)
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            receive(event)
            return event
        }
        if effect.followsHeldPointer {
            refreshHover = { [weak self] in
                guard let self, effect.respondsToHover || releaseWatchdog != nil else { return }
                let point = NSEvent.mouseLocation
                if let id = Self.windowUnderPointer(at: point), Self.isDesktopWindow(id) {
                    let input: DesktopPointerInput = releaseWatchdog == nil ? .movement : .pressMoved
                    handler(input, point)
                } else {
                    onExit()
                }
            }
            refreshPointerPosition()
        }
    }

    func refreshPointerPosition() {
        refreshHover?()
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        cancelReleaseWatchdog()
        gesture.cancel()
        marquee.cancel()
        pointerSampler = DesktopPointerSampler()
        refreshHover = nil
    }

    private func observePointer(
        _ event: NSEvent, throttle: Bool, input: DesktopPointerInput = .movement,
        handler: (DesktopPointerInput, NSPoint) -> Void, onExit: () -> Void
    ) {
        guard let cgEvent = event.cgEvent else { onExit(); return }
        let point = cgEvent.unflippedLocation
        guard let isDesktop = pointerSampler.desktopHit(
            at: event.timestamp, throttle: throttle,
            hitWindow: { Self.hitWindow(for: cgEvent, at: point) },
            isDesktopWindow: Self.isDesktopWindow
        ) else { return }
        if isDesktop { handler(input, point) } else { onExit() }
    }

    private func observePress(
        _ event: NSEvent, respondsToHover: Bool, handler: @escaping (DesktopPointerInput, NSPoint) -> Void,
        onExit: () -> Void
    ) {
        switch event.type {
        case .leftMouseDown:
            cancelReleaseWatchdog()
            guard !event.modifierFlags.contains(.control), let mouse = event.cgEvent,
                  let window = Self.hitWindow(for: mouse, at: mouse.unflippedLocation),
                  Self.isDesktopWindow(window) else { onExit(); return }
            handler(.pressBegan, mouse.unflippedLocation)
            // Finder can own the rest of a drag. Release the effect even if its
            // native drag session consumes the final mouse-up event.
            releaseWatchdog = Task { @MainActor [weak self] in
                repeat {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                } while NSEvent.pressedMouseButtons & 1 != 0
                guard !Task.isCancelled else { return }
                self?.finishPress(handler)
                self?.refreshPointerPosition()
            }
        case .leftMouseDragged:
            guard respondsToHover || releaseWatchdog != nil else { return }
            let input: DesktopPointerInput = releaseWatchdog == nil ? .movement : .pressMoved
            observePointer(event, throttle: false, input: input, handler: handler, onExit: onExit)
        case .leftMouseUp:
            finishPress(handler)
            // A stationary pointer must return to its ordinary hover appearance on release.
            if respondsToHover { observePointer(event, throttle: false, handler: handler, onExit: onExit) }
        default:
            break
        }
    }

    private func finishPress(_ handler: (DesktopPointerInput, NSPoint) -> Void) {
        guard releaseWatchdog != nil else { return }
        cancelReleaseWatchdog()
        handler(.pressEnded, NSEvent.mouseLocation)
    }

    private func cancelReleaseWatchdog() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
    }

    private func observeClick(_ event: NSEvent, handler: (NSPoint) -> Void) {
        guard event.type == .leftMouseDown || gesture.isTracking else { return }
        let selectionModifiers: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
        guard event.modifierFlags.intersection(selectionModifiers).isEmpty,
              let cgEvent = event.cgEvent else {
            gesture.cancel()
            return
        }
        let point = cgEvent.unflippedLocation
        switch event.type {
        case .leftMouseDown:
            gesture.begin(at: point, windowID: Self.hitWindow(for: cgEvent, at: point), time: event.timestamp)
        case .leftMouseDragged:
            gesture.drag(to: point)
        case .leftMouseUp:
            let hit = Self.hitWindow(for: cgEvent, at: point)
            if let id = gesture.finish(at: point, windowID: hit, time: event.timestamp),
               Self.isDesktopWindow(id) {
                handler(point)
            }
        default:
            break
        }
    }

    private func observeMarquee(_ event: NSEvent, handler: (CGRect) -> Void) {
        guard !event.modifierFlags.contains(.control), let mouse = event.cgEvent else {
            marquee.cancel()
            return
        }
        let point = mouse.unflippedLocation
        switch event.type {
        case .leftMouseDown:
            marquee.cancel()
            guard let window = Self.hitWindow(for: mouse, at: point), Self.isDesktopWindow(window) else { return }
            marquee.begin(at: point, desktopWindow: window, dragChangeCount: Self.dragChangeCount)
        case .leftMouseDragged:
            guard let start = marquee.startingWindow else { return }
            // The raw hit can be the system's drag image. The actionable hit
            // can still be the Finder desktop during a file drag.
            let rawHit = mouse.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            let rawWindow = CGWindowID(exactly: rawHit)
            let overDragImage = rawWindow.map { id in
                id != kCGNullWindowID && id != start && Self.windowLevel(id) == CGWindowLevelForKey(.draggingWindow)
            } ?? false
            marquee.drag(overFileDragImage: overDragImage)
        case .leftMouseUp:
            guard marquee.startingWindow != nil else { return }
            let window = Self.hitWindow(for: mouse, at: point)
            if let rect = marquee.finish(at: point, window: window, dragChangeCount: Self.dragChangeCount) {
                handler(rect)
            }
        default:
            break
        }
    }

    // Dragging a Finder item claims the drag pasteboard; drawing a selection
    // rectangle does not. Both gestures can start and end in the same window.
    // Only inspect ownership changes, never types, URLs, or clipboard contents.
    private static var dragChangeCount: Int { NSPasteboard(name: .drag).changeCount }

    private static func hitWindow(for event: CGEvent, at point: NSPoint) -> CGWindowID? {
        let originalHit = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        if let id = CGWindowID(exactly: originalHit), id != kCGNullWindowID {
            return id
        }
        return windowUnderPointer(at: point)
    }

    private static func windowUnderPointer(at point: NSPoint) -> CGWindowID? {
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let id = CGWindowID(exactly: hit), id != kCGNullWindowID else { return nil }
        return id
    }

    private static func isDesktopWindow(_ id: CGWindowID) -> Bool {
        windowLevel(id).map(isDesktopLayer) ?? false
    }

    private static func windowLevel(_ id: CGWindowID) -> Int32? {
        // Query only the hit window. The layer is available without screen
        // recording permission, and distinguishes Finder windows from its desktop.
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        return rows?.first?[kCGWindowLayer as String] as? Int32
    }

    static func isDesktopLayer(_ layer: Int32) -> Bool {
        layer == CGWindowLevelForKey(.desktopWindow) || layer == CGWindowLevelForKey(.desktopIconWindow)
    }
}
