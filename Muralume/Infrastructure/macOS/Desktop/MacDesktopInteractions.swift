import AppKit

@MainActor
final class MacDesktopInteractions {
    struct Display {
        let surface: DesktopPlayerLayerSurfaceView
        let window: NSWindow
        let isVisible: Bool
    }

    private let workspaceCenter: NotificationCenter
    private let displays: () -> [Display]
    private let monitor = MacDesktopClickMonitor()
    private weak var pointerSurface: DesktopPlayerLayerSurfaceView?
    private var motionObserver: NSObjectProtocol?
    private var effect: DesktopInteractionEffect = .off
    private var hoverEnabled = false

    init(workspaceCenter: NotificationCenter, displays: @escaping () -> [Display]) {
        self.workspaceCenter = workspaceCenter
        self.displays = displays
    }

    isolated deinit {
        if let motionObserver { workspaceCenter.removeObserver(motionObserver) }
        monitor.stop()
    }

    func setEffect(_ effect: DesktopInteractionEffect) {
        self.effect = effect
        if effect == .off, let motionObserver {
            workspaceCenter.removeObserver(motionObserver)
            self.motionObserver = nil
        } else if effect != .off, motionObserver == nil {
            motionObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMonitoring() }
            }
        }
        updateMonitoring()
    }

    private func updateMonitoring() {
        monitor.stop()
        leaveDesktop()
        let enabled = effect != .off && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hoverEnabled = enabled && effect.followsHeldPointer
        for display in displays() {
            display.surface.clearDesktopEffects()
            configureHover(on: display.surface)
        }
        guard enabled else { return }
        dimVisibleVideos()
        monitor.start(for: effect) { [weak self] input, point in
            self?.handlePointer(input, at: point)
        } onExit: { [weak self] in
            self?.leaveDesktop()
        } onMarquee: { [weak self] selection in
            self?.applySelection(selection)
        }
    }

    func configureHover(on surface: DesktopPlayerLayerSurfaceView) {
        surface.refreshPointerPosition = hoverEnabled ? { [weak self] in self?.refreshPointerPosition() } : nil
    }

    func refreshPointerPosition() {
        dimVisibleVideos()
        monitor.refreshPointerPosition()
    }

    private func dimVisibleVideos() {
        guard hoverEnabled, effect == .shadowLight else { return }
        for display in displays() where display.isVisible {
            display.surface.dimDesktopVideo()
        }
    }

    private func leaveDesktop() {
        pointerSurface?.desktopPointerDidLeave()
        pointerSurface = nil
    }

    private func handlePointer(_ input: DesktopPointerInput, at point: CGPoint) {
        if input == .pressEnded {
            if effect == .colorFocus { pointerSurface?.endDesktopColorPick() }
            return
        }
        guard let display = displays().first(where: { $0.isVisible && $0.window.frame.contains(point) }) else {
            leaveDesktop()
            return
        }
        if pointerSurface !== display.surface {
            leaveDesktop()
            pointerSurface = display.surface
        }
        let windowPoint = display.window.convertPoint(fromScreen: point)
        let videoPoint = display.surface.convert(windowPoint, from: nil)
        display.surface.handleDesktopInteraction(effect, input: input, at: videoPoint)
    }

    private func applySelection(_ selection: CGRect) {
        guard effect == .localFreeze else { return }
        for display in displays() where display.isVisible {
            let screenRect = selection.intersection(display.window.frame)
            guard !screenRect.isEmpty else { continue }
            let windowRect = display.window.convertFromScreen(screenRect)
            display.surface.freezeDesktopSelection(display.surface.convert(windowRect, from: nil))
        }
    }
}
