import AppKit
import CoreGraphics

private enum DesktopScreenKey {
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

final class UserDefaultsDesktopVideoContentModeStore:
    DesktopVideoContentModeStoring {
    private enum Storage {
        static let contentModeKey = "desktop.video-content-mode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DesktopVideoContentMode {
        guard let rawValue = defaults.string(forKey: Storage.contentModeKey),
              let contentMode = DesktopVideoContentMode(rawValue: rawValue) else {
            return .defaultValue
        }
        return contentMode
    }

    func save(_ contentMode: DesktopVideoContentMode) {
        defaults.set(contentMode.rawValue, forKey: Storage.contentModeKey)
    }
}

@MainActor
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class MacDesktopHost: DesktopHosting {
    private(set) var surface: DesktopPlayerLayerSurfaceView?

    private var window: DesktopWindow?
    private var screenObserver: NSObjectProtocol?

    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface {
        close()

        let targetScreen = Self.primaryScreen
        let frame = targetScreen?.frame ?? .zero
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: contentMode
        )
        surface.frame = NSRect(origin: .zero, size: frame.size)
        surface.autoresizingMask = [.width, .height]

        let window = DesktopWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = surface
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.isMovable = false
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.level = Self.desktopVideoLevel
        window.alphaValue = 0.01
        window.orderFrontRegardless()

        self.surface = surface
        self.window = window
        installScreenObserver()
        return surface
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        surface?.setContentMode(contentMode)
    }

    func reveal() {
        guard let window else {
            return
        }
        window.alphaValue = 1
        reassertDesktopPlacement()
    }

    func reassertDesktopPlacement() {
        guard let window else {
            return
        }
        let screen = resolvedScreen()
        if let screen {
            window.setFrame(screen.frame, display: true)
        }
        window.level = Self.desktopVideoLevel
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        surface?.connect(to: nil)
        surface = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reassertDesktopPlacement()
            }
        }
    }

    private func resolvedScreen() -> NSScreen? {
        Self.primaryScreen
    }

    private static var desktopVideoLevel: NSWindow.Level {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let levelAboveWallpaper = desktopLevel + 1
        let levelBelowIcons = desktopIconLevel - 1
        return NSWindow.Level(rawValue: min(levelAboveWallpaper, levelBelowIcons))
    }

    private static var primaryScreen: NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[DesktopScreenKey.screenNumber]
                as? NSNumber else {
                return false
            }
            return screenNumber.uint32Value == mainDisplayID
        } ?? NSScreen.screens.first
    }
}
