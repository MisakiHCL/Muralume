import AppKit
import ColorSync
import CoreGraphics

private enum DesktopTopologyScreenKey {
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

private enum DesktopIdentificationOverlayPolicy {
    static let width: CGFloat = 160
    static let height: CGFloat = 112
    static let cornerRadius: CGFloat = 16
    static let fontSize: CGFloat = 48
    static let backgroundOpacity: CGFloat = 0.82
    static let visibleDuration: Duration = .seconds(2)
}

enum MacDesktopDisplayIdentityResolver {
    static func stableID(
        for displayID: CGDirectDisplayID
    ) -> DesktopDisplayID {
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = unmanagedUUID.takeRetainedValue()
            let value = CFUUIDCreateString(nil, uuid) as String
            return DesktopDisplayID(
                rawValue: "cgdisplay:\(value.lowercased())"
            )
        }

        let serialNumber = CGDisplaySerialNumber(displayID)
        if serialNumber != 0 {
            return DesktopDisplayID(
                rawValue: [
                    "hardware",
                    String(CGDisplayVendorNumber(displayID)),
                    String(CGDisplayModelNumber(displayID)),
                    String(serialNumber),
                    String(CGDisplayIsBuiltin(displayID) != 0)
                ].joined(separator: ":")
            )
        }

        let screenSize = CGDisplayScreenSize(displayID)
        let physicalWidth = Int(screenSize.width.rounded())
        let physicalHeight = Int(screenSize.height.rounded())
        return DesktopDisplayID(
            rawValue: [
                "hardware",
                String(CGDisplayVendorNumber(displayID)),
                String(CGDisplayModelNumber(displayID)),
                "no-serial",
                String(CGDisplayIsBuiltin(displayID) != 0),
                "\(physicalWidth)x\(physicalHeight)",
                String(CGDisplayUnitNumber(displayID))
            ].joined(separator: ":")
        )
    }
}

@MainActor
final class MacDesktopDisplayTopology: DesktopDisplayTopologyProviding {
    var displaysDidChangeHandler:
        (([DesktopDisplayDescriptor]) -> Void)?

    private let notificationCenter: NotificationCenter
    private var screenObserver: NSObjectProtocol?
    private var identificationWindows: [NSWindow] = []
    private var identificationTask: Task<Void, Never>?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func currentDisplays() -> [DesktopDisplayDescriptor] {
        NSScreen.screens.compactMap(Self.descriptor(for:))
    }

    func startMonitoring() {
        guard screenObserver == nil else {
            return
        }
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                displaysDidChangeHandler?(currentDisplays())
            }
        }
    }

    func stopMonitoring() {
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        dismissIdentificationWindows()
    }

    func identifyDisplays() {
        dismissIdentificationWindows()
        let screensByRuntimeID = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                Self.runtimeDisplayID(for: screen).map { ($0, screen) }
            }
        )
        let displays = currentDisplays()
        for (index, display) in displays.enumerated() {
            guard let screen = screensByRuntimeID[display.runtimeID] else {
                continue
            }
            let window = Self.makeIdentificationWindow(
                number: index + 1,
                screen: screen
            )
            identificationWindows.append(window)
            window.orderFrontRegardless()
        }

        identificationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: DesktopIdentificationOverlayPolicy.visibleDuration
                )
            } catch {
                return
            }
            self?.dismissIdentificationWindows()
        }
    }

    private func dismissIdentificationWindows() {
        identificationTask?.cancel()
        identificationTask = nil
        identificationWindows.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        identificationWindows.removeAll()
    }

    private static func descriptor(
        for screen: NSScreen
    ) -> DesktopDisplayDescriptor? {
        guard let runtimeID = runtimeDisplayID(for: screen) else {
            return nil
        }
        let displayID = CGDirectDisplayID(runtimeID.rawValue)
        guard CGDisplayMirrorsDisplay(displayID)
                == kCGNullDirectDisplay else {
            return nil
        }

        return DesktopDisplayDescriptor(
            id: MacDesktopDisplayIdentityResolver.stableID(for: displayID),
            runtimeID: runtimeID,
            localizedName: screen.localizedName,
            frame: screen.frame,
            isMain: CGDisplayIsMain(displayID) != 0,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
        )
    }

    private static func runtimeDisplayID(
        for screen: NSScreen
    ) -> DesktopRuntimeDisplayID? {
        guard let number = screen.deviceDescription[
            DesktopTopologyScreenKey.screenNumber
        ]
                as? NSNumber else {
            return nil
        }
        return DesktopRuntimeDisplayID(rawValue: number.uint32Value)
    }

    private static func makeIdentificationWindow(
        number: Int,
        screen: NSScreen
    ) -> NSWindow {
        let size = NSSize(
            width: DesktopIdentificationOverlayPolicy.width,
            height: DesktopIdentificationOverlayPolicy.height
        )
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = NSColor.black.withAlphaComponent(
            DesktopIdentificationOverlayPolicy.backgroundOpacity
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver

        let label = NSTextField(labelWithString: String(number))
        label.alignment = .center
        label.font = NSFont.systemFont(
            ofSize: DesktopIdentificationOverlayPolicy.fontSize,
            weight: .bold
        )
        label.textColor = .white
        label.frame = NSRect(origin: .zero, size: size)
        label.autoresizingMask = [.width, .height]

        let contentView = NSView(frame: NSRect(origin: .zero, size: size))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius =
            DesktopIdentificationOverlayPolicy.cornerRadius
        contentView.layer?.masksToBounds = true
        contentView.addSubview(label)
        window.contentView = contentView
        return window
    }
}
