import AppKit
import CoreGraphics

private enum DesktopScreenKey {
    static let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
}

private enum DesktopDisplayTopologyPolicy {
    static let emptyTopologyGracePeriodNanoseconds: UInt64 = 500_000_000
    static let initialDeferredRevealPollIntervalNanoseconds: UInt64 =
        250_000_000
    static let maximumDeferredRevealPollIntervalNanoseconds: UInt64 =
        4_000_000_000
}

struct MacDesktopDisplayID: Hashable, Comparable {
    let rawValue: CGDirectDisplayID

    static func < (
        lhs: MacDesktopDisplayID,
        rhs: MacDesktopDisplayID
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MacDesktopDisplay {
    let id: MacDesktopDisplayID
    let frame: NSRect
    let screen: NSScreen?

    init(
        id: CGDirectDisplayID,
        frame: NSRect,
        screen: NSScreen? = nil
    ) {
        self.id = MacDesktopDisplayID(rawValue: id)
        self.frame = frame
        self.screen = screen
    }
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
    private struct HostedDisplay {
        let window: DesktopWindow
        let surface: DesktopPlayerLayerSurfaceView
        var frame: NSRect
    }

    private(set) var surface: DesktopPlayerLayerSurfaceGroup?

    var hostedDisplayIDs: Set<MacDesktopDisplayID> {
        Set(hostedDisplays.keys)
    }

    var hostedWindowCount: Int {
        hostedDisplays.count
    }

    var hostedWindowFrames: [MacDesktopDisplayID: NSRect] {
        hostedDisplays.mapValues(\.window.frame)
    }

    var hostedWindowAlphaValues: [MacDesktopDisplayID: CGFloat] {
        hostedDisplays.mapValues(\.window.alphaValue)
    }

    private let notificationCenter: NotificationCenter
    private let displaysProvider: () -> [MacDesktopDisplay]
    private let isSurfaceReady: (DesktopPlayerLayerSurfaceView) -> Bool
    private let emptyTopologyGracePeriodNanoseconds: UInt64
    private var hostedDisplays: [MacDesktopDisplayID: HostedDisplay] = [:]
    private var displayRevealTasks: [
        MacDesktopDisplayID: Task<Void, Never>
    ] = [:]
    private var emptyTopologyTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var contentMode = DesktopVideoContentMode.defaultValue
    private var isEnergyConstrained = false
    private var isRevealed = false

    init(
        notificationCenter: NotificationCenter = .default,
        displaysProvider: @escaping () -> [MacDesktopDisplay] = {
            MacDesktopHost.currentDisplays
        },
        isSurfaceReady: @escaping (
            DesktopPlayerLayerSurfaceView
        ) -> Bool = { $0.isReadyForDisplay },
        emptyTopologyGracePeriodNanoseconds: UInt64 =
            DesktopDisplayTopologyPolicy.emptyTopologyGracePeriodNanoseconds
    ) {
        self.notificationCenter = notificationCenter
        self.displaysProvider = displaysProvider
        self.isSurfaceReady = isSurfaceReady
        self.emptyTopologyGracePeriodNanoseconds =
            emptyTopologyGracePeriodNanoseconds
    }

    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface {
        close()
        self.contentMode = contentMode
        isRevealed = false
        let surface = DesktopPlayerLayerSurfaceGroup(id: .desktop)
        surface.setEnergyConstrained(isEnergyConstrained)
        self.surface = surface
        reconcileDisplays()
        installScreenObserver()
        return surface
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        self.contentMode = contentMode
        surface?.setContentMode(contentMode)
    }

    func setEnergyConstrained(_ isEnergyConstrained: Bool) {
        guard self.isEnergyConstrained != isEnergyConstrained else {
            return
        }
        self.isEnergyConstrained = isEnergyConstrained
        surface?.setEnergyConstrained(isEnergyConstrained)
    }

    func reveal() {
        guard surface != nil else {
            return
        }
        isRevealed = true
        reassertDesktopPlacement()
    }

    func reassertDesktopPlacement() {
        guard surface != nil else {
            return
        }
        reconcileDisplays()
        if isRevealed {
            for (displayID, hostedDisplay) in hostedDisplays
                where hostedDisplay.window.alphaValue < 1 {
                revealWhenReady(displayID, surface: hostedDisplay.surface)
            }
        }
        hostedDisplays.values.forEach(Self.reassertPlacement)
    }

    func close() {
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        cancelPendingTopologyWork()
        isRevealed = false
        surface?.replaceDisplaySurfaces([])
        surface?.connect(to: nil)
        surface = nil
        hostedDisplays.values.forEach(Self.tearDown)
        hostedDisplays.removeAll()
    }

    private func installScreenObserver() {
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reassertDesktopPlacement()
            }
        }
    }

    private func reconcileDisplays(
        allowStableEmptyTopology: Bool = false
    ) {
        let displays = displaysProvider().reduce(
            into: [MacDesktopDisplayID: MacDesktopDisplay]()
        ) { result, display in
            guard display.frame.width > 0, display.frame.height > 0 else {
                return
            }
            result[display.id] = display
        }
        if displays.isEmpty,
           !hostedDisplays.isEmpty,
           !allowStableEmptyTopology {
            scheduleEmptyTopologyRecheck()
            return
        }
        cancelEmptyTopologyRecheck()
        let removedDisplayIDs = Set(hostedDisplays.keys)
            .subtracting(displays.keys)
        var removedDisplays: [HostedDisplay] = []
        var addedDisplayIDs: Set<MacDesktopDisplayID> = []

        for displayID in removedDisplayIDs {
            cancelReveal(for: displayID)
            if let removedDisplay = hostedDisplays.removeValue(
                forKey: displayID
            ) {
                removedDisplays.append(removedDisplay)
            }
        }

        for (displayID, display) in displays {
            if var hostedDisplay = hostedDisplays[displayID] {
                hostedDisplay.frame = display.frame
                hostedDisplay.window.setFrame(display.frame, display: true)
                hostedDisplays[displayID] = hostedDisplay
            } else {
                hostedDisplays[displayID] = makeHostedDisplay(for: display)
                addedDisplayIDs.insert(displayID)
            }
        }

        let orderedSurfaces = hostedDisplays.keys.sorted().compactMap {
            hostedDisplays[$0]?.surface
        }
        surface?.replaceDisplaySurfaces(orderedSurfaces)

        if isRevealed {
            for displayID in addedDisplayIDs {
                guard let hostedDisplay = hostedDisplays[displayID] else {
                    continue
                }
                revealWhenReady(displayID, surface: hostedDisplay.surface)
            }
        }

        removedDisplays.forEach(Self.tearDown)
    }

    private func makeHostedDisplay(
        for display: MacDesktopDisplay
    ) -> HostedDisplay {
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: contentMode
        )
        surface.setEnergyConstrained(isEnergyConstrained)
        surface.frame = NSRect(origin: .zero, size: display.frame.size)
        surface.autoresizingMask = [.width, .height]

        let window = DesktopWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: display.screen
        )
        window.backgroundColor = .black
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]
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

        return HostedDisplay(
            window: window,
            surface: surface,
            frame: display.frame
        )
    }

    private func revealWhenReady(
        _ displayID: MacDesktopDisplayID,
        surface: DesktopPlayerLayerSurfaceView
    ) {
        guard isRevealed, displayRevealTasks[displayID] == nil else {
            return
        }
        if isSurfaceReady(surface) {
            hostedDisplays[displayID]?.window.alphaValue = 1
            return
        }

        displayRevealTasks[displayID] = Task { @MainActor [weak self, weak surface] in
            var fastPollingElapsedNanoseconds: UInt64 = 0
            var pollIntervalNanoseconds =
                PlaybackPolicy.surfacePollIntervalNanoseconds
            while !Task.isCancelled {
                let shouldKeepWaiting = { [weak self, weak surface] in
                    guard let self,
                          let surface,
                          self.isRevealed,
                          self.hostedDisplays[displayID]?.surface === surface else {
                        return false
                    }
                    if self.isSurfaceReady(surface) {
                        self.hostedDisplays[displayID]?.window.alphaValue = 1
                        self.displayRevealTasks[displayID] = nil
                        return false
                    }
                    return true
                }()
                guard shouldKeepWaiting else {
                    return
                }
                try? await Task.sleep(
                    nanoseconds: pollIntervalNanoseconds
                )
                if fastPollingElapsedNanoseconds
                    < PlaybackPolicy.surfaceReadyTimeoutNanoseconds {
                    fastPollingElapsedNanoseconds += pollIntervalNanoseconds
                    if fastPollingElapsedNanoseconds
                        >= PlaybackPolicy.surfaceReadyTimeoutNanoseconds {
                        pollIntervalNanoseconds = DesktopDisplayTopologyPolicy
                            .initialDeferredRevealPollIntervalNanoseconds
                    }
                } else {
                    pollIntervalNanoseconds = min(
                        pollIntervalNanoseconds * 2,
                        DesktopDisplayTopologyPolicy
                            .maximumDeferredRevealPollIntervalNanoseconds
                    )
                }
            }
        }
    }

    private func scheduleEmptyTopologyRecheck() {
        guard emptyTopologyTask == nil else {
            return
        }
        let gracePeriodNanoseconds = emptyTopologyGracePeriodNanoseconds
        emptyTopologyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: gracePeriodNanoseconds
            )
            guard !Task.isCancelled, let self else {
                return
            }
            emptyTopologyTask = nil
            reconcileDisplays(allowStableEmptyTopology: true)
        }
    }

    private func cancelReveal(for displayID: MacDesktopDisplayID) {
        displayRevealTasks.removeValue(forKey: displayID)?.cancel()
    }

    private func cancelEmptyTopologyRecheck() {
        emptyTopologyTask?.cancel()
        emptyTopologyTask = nil
    }

    private func cancelPendingTopologyWork() {
        displayRevealTasks.values.forEach { $0.cancel() }
        displayRevealTasks.removeAll()
        cancelEmptyTopologyRecheck()
    }

    private static func reassertPlacement(
        _ hostedDisplay: HostedDisplay
    ) {
        hostedDisplay.window.setFrame(hostedDisplay.frame, display: true)
        hostedDisplay.window.level = desktopVideoLevel
        hostedDisplay.window.ignoresMouseEvents = true
        hostedDisplay.window.orderFrontRegardless()
    }

    private static func tearDown(_ hostedDisplay: HostedDisplay) {
        hostedDisplay.surface.connect(to: nil)
        hostedDisplay.window.orderOut(nil)
        hostedDisplay.window.contentView = nil
        hostedDisplay.window.close()
    }

    private static var desktopVideoLevel: NSWindow.Level {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let levelAboveWallpaper = desktopLevel + 1
        let levelBelowIcons = desktopIconLevel - 1
        return NSWindow.Level(rawValue: min(levelAboveWallpaper, levelBelowIcons))
    }

    private static var currentDisplays: [MacDesktopDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[DesktopScreenKey.screenNumber]
                as? NSNumber else {
                return nil
            }
            let displayID = screenNumber.uint32Value
            // The mirror primary already supplies the drawable desktop for
            // the whole mirror set; a second window would duplicate work.
            guard CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else {
                return nil
            }
            return MacDesktopDisplay(
                id: displayID,
                frame: screen.frame,
                screen: screen
            )
        }
    }
}
