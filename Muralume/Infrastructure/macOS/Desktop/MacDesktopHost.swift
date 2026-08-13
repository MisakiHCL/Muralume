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

private enum DesktopOcclusionPolicy {
    static let debounceNanoseconds: UInt64 = 750_000_000
    static let revealedWindowAlphaThreshold: CGFloat = 0.99
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
        let stableID: DesktopDisplayID
        let window: DesktopWindow
        let surface: DesktopPlayerLayerSurfaceView
        var frame: NSRect
    }

    private(set) var surface: DesktopPlayerLayerSurfaceGroup?

    var desktopOcclusionHandler: ((Bool) -> Void)? {
        didSet {
            desktopOcclusionHandler?(isDesktopOccluded)
        }
    }

    private(set) var isDesktopOccluded = false
    var isDesktopOcclusionDebouncePending: Bool {
        occlusionDebounceTask != nil
    }

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

    var hostedWindows: [MacDesktopDisplayID: DesktopWindow] {
        hostedDisplays.mapValues(\.window)
    }

    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let displaysProvider: () -> [MacDesktopDisplay]
    private let isSurfaceReady: (DesktopPlayerLayerSurfaceView) -> Bool
    private let isWindowVisible: (DesktopWindow) -> Bool
    private let emptyTopologyGracePeriodNanoseconds: UInt64
    private let occlusionDebounceNanoseconds: UInt64
    private var hostedDisplays: [MacDesktopDisplayID: HostedDisplay] = [:]
    private var displayRevealTasks: [
        MacDesktopDisplayID: Task<Void, Never>
    ] = [:]
    private var emptyTopologyTask: Task<Void, Never>?
    private var occlusionDebounceTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowOcclusionObservers: [
        MacDesktopDisplayID: NSObjectProtocol
    ] = [:]
    private var contentMode = DesktopVideoContentMode.defaultValue
    private var scene = DesktopScene.legacy(
        contentMode: DesktopVideoContentMode.defaultValue
    )
    private var displaySurfaceEventHandler:
        ((DesktopDisplaySurfaceEvent) -> Void)?
    private var isEnergyConstrained = false
    private var isRevealed = false

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared
            .notificationCenter,
        displaysProvider: @escaping () -> [MacDesktopDisplay] = {
            MacDesktopHost.currentDisplays
        },
        isSurfaceReady: @escaping (
            DesktopPlayerLayerSurfaceView
        ) -> Bool = { $0.isReadyForDisplay },
        isWindowVisible: @escaping (DesktopWindow) -> Bool = {
            $0.occlusionState.contains(.visible)
        },
        emptyTopologyGracePeriodNanoseconds: UInt64 =
            DesktopDisplayTopologyPolicy.emptyTopologyGracePeriodNanoseconds,
        occlusionDebounceNanoseconds: UInt64 =
            DesktopOcclusionPolicy.debounceNanoseconds
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        self.displaysProvider = displaysProvider
        self.isSurfaceReady = isSurfaceReady
        self.isWindowVisible = isWindowVisible
        self.emptyTopologyGracePeriodNanoseconds =
            emptyTopologyGracePeriodNanoseconds
        self.occlusionDebounceNanoseconds = occlusionDebounceNanoseconds
    }

    func prepare(
        contentMode: DesktopVideoContentMode
    ) -> any PlaybackRenderSurface {
        prepare(
            scene: .legacy(contentMode: contentMode)
        ).synchronizedSurface
    }

    func prepare(scene: DesktopScene) -> DesktopHostPreparation {
        close()
        self.scene = scene
        contentMode = scene.defaultContentMode
        isRevealed = false
        let surface = DesktopPlayerLayerSurfaceGroup(id: .desktop)
        surface.setEnergyConstrained(isEnergyConstrained)
        self.surface = surface
        reconcileDisplays()
        installScreenObserver()
        installWorkspaceObservers()
        return DesktopHostPreparation(
            synchronizedSurface: surface,
            displaySurfaces: displaySurfacesByStableID
        )
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        self.contentMode = contentMode
        surface?.setContentMode(contentMode)
    }

    func setVideoContentMode(
        _ contentMode: DesktopVideoContentMode,
        for displayID: DesktopDisplayID
    ) {
        hostedDisplays.values
            .first { $0.stableID == displayID }?
            .surface.setContentMode(contentMode)
    }

    func setDisplaySurfaceEventHandler(
        _ handler: ((DesktopDisplaySurfaceEvent) -> Void)?
    ) {
        displaySurfaceEventHandler = handler
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
        refreshDesktopOcclusionState()
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
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        windowOcclusionObservers.values.forEach(
            notificationCenter.removeObserver
        )
        windowOcclusionObservers.removeAll()
        cancelPendingTopologyWork()
        cancelOcclusionDebounce()
        isRevealed = false
        surface?.replaceDisplaySurfaces([])
        surface?.connect(to: nil)
        surface = nil
        hostedDisplays.values.forEach(Self.tearDown)
        hostedDisplays.removeAll()
        publishDesktopOcclusion(false)
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

    private func installWorkspaceObservers() {
        let notificationNames: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        workspaceObservers = notificationNames.map { name in
            workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDesktopOcclusionState()
                }
            }
        }
    }

    private func reconcileDisplays(
        allowStableEmptyTopology: Bool = false
    ) {
        let displays = displaysProvider().reduce(
            into: [MacDesktopDisplayID: MacDesktopDisplay]()
        ) { result, display in
            guard display.frame.width > 0,
                  display.frame.height > 0,
                  isEnabled(display) else {
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
            removeOcclusionObserver(for: displayID)
            if let removedDisplay = hostedDisplays.removeValue(
                forKey: displayID
            ) {
                displaySurfaceEventHandler?(
                    .willRemove(displayID: removedDisplay.stableID)
                )
                removedDisplays.append(removedDisplay)
            }
        }

        for (displayID, display) in displays {
            if var hostedDisplay = hostedDisplays[displayID] {
                hostedDisplay.frame = display.frame
                hostedDisplay.window.setFrame(display.frame, display: true)
                hostedDisplays[displayID] = hostedDisplay
            } else {
                let hostedDisplay = makeHostedDisplay(for: display)
                hostedDisplays[displayID] = hostedDisplay
                installOcclusionObserver(
                    for: displayID,
                    window: hostedDisplay.window
                )
                addedDisplayIDs.insert(displayID)
            }
        }

        let orderedSurfaces = hostedDisplays.keys.sorted().compactMap {
            hostedDisplays[$0]?.surface
        }
        surface?.replaceDisplaySurfaces(orderedSurfaces)

        for displayID in addedDisplayIDs {
            guard let hostedDisplay = hostedDisplays[displayID] else {
                continue
            }
            displaySurfaceEventHandler?(
                .didAdd(
                    displayID: hostedDisplay.stableID,
                    surface: hostedDisplay.surface
                )
            )
        }

        if isRevealed {
            for displayID in addedDisplayIDs {
                guard let hostedDisplay = hostedDisplays[displayID] else {
                    continue
                }
                revealWhenReady(displayID, surface: hostedDisplay.surface)
            }
        }

        removedDisplays.forEach(Self.tearDown)
        refreshDesktopOcclusionState()
    }

    private func makeHostedDisplay(
        for display: MacDesktopDisplay
    ) -> HostedDisplay {
        let stableID = stableDisplayID(for: display)
        let displayContentMode = scene.mode == .synchronized
            ? scene.defaultContentMode
            : scene.assignment(for: stableID)?.contentMode
                ?? scene.defaultContentMode
        let surface = DesktopPlayerLayerSurfaceView(
            id: .desktop,
            contentMode: displayContentMode
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
            stableID: stableID,
            window: window,
            surface: surface,
            frame: display.frame
        )
    }

    private var displaySurfacesByStableID: [
        DesktopDisplayID: any PlaybackRenderSurface
    ] {
        hostedDisplays.values.reduce(into: [:]) { result, hostedDisplay in
            result[hostedDisplay.stableID] = hostedDisplay.surface
        }
    }

    private func stableDisplayID(
        for display: MacDesktopDisplay
    ) -> DesktopDisplayID {
        MacDesktopDisplayIdentityResolver.stableID(
            for: display.id.rawValue
        )
    }

    private func isEnabled(_ display: MacDesktopDisplay) -> Bool {
        let displayID = stableDisplayID(for: display)
        if scene.mode == .synchronized,
           scene.appliesToAllConnectedDisplays,
           scene.assignment(for: displayID) == nil {
            return true
        }
        return scene.assignment(for: displayID)?.isEnabled == true
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
            refreshDesktopOcclusionState()
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
                        self.refreshDesktopOcclusionState()
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

    private func installOcclusionObserver(
        for displayID: MacDesktopDisplayID,
        window: DesktopWindow
    ) {
        removeOcclusionObserver(for: displayID)
        windowOcclusionObservers[displayID] = notificationCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDesktopOcclusionState()
            }
        }
    }

    private func removeOcclusionObserver(
        for displayID: MacDesktopDisplayID
    ) {
        guard let observer = windowOcclusionObservers.removeValue(
            forKey: displayID
        ) else {
            return
        }
        notificationCenter.removeObserver(observer)
    }

    private func refreshDesktopOcclusionState() {
        let eligibleWindows = occlusionEligibleWindows
        guard isRevealed, !hostedDisplays.isEmpty else {
            cancelOcclusionDebounce()
            publishDesktopOcclusion(false)
            return
        }
        guard !eligibleWindows.isEmpty else {
            cancelOcclusionDebounce()
            // A hot-plugged replacement can be connected before its first
            // frame is ready. Preserve the last known state until at least one
            // desktop window becomes observable instead of resuming hidden
            // decoding or preemptively pausing the frame needed for readiness.
            return
        }

        let isFullyOccluded = eligibleWindows.allSatisfy {
            !isWindowVisible($0)
        }
        guard isFullyOccluded else {
            cancelOcclusionDebounce()
            publishDesktopOcclusion(false)
            return
        }
        scheduleOcclusionDebounceIfNeeded()
    }

    private var occlusionEligibleWindows: [DesktopWindow] {
        hostedDisplays.values.compactMap { hostedDisplay in
            let window = hostedDisplay.window
            guard window.alphaValue
                >= DesktopOcclusionPolicy.revealedWindowAlphaThreshold else {
                return nil
            }
            return window
        }
    }

    private func scheduleOcclusionDebounceIfNeeded() {
        guard !isDesktopOccluded, occlusionDebounceTask == nil else {
            return
        }
        let debounceNanoseconds = occlusionDebounceNanoseconds
        occlusionDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            occlusionDebounceTask = nil
            let eligibleWindows = occlusionEligibleWindows
            guard isRevealed,
                  !eligibleWindows.isEmpty,
                  eligibleWindows.allSatisfy({
                      !isWindowVisible($0)
                  }) else {
                return
            }
            publishDesktopOcclusion(true)
        }
    }

    private func cancelOcclusionDebounce() {
        occlusionDebounceTask?.cancel()
        occlusionDebounceTask = nil
    }

    private func publishDesktopOcclusion(_ isOccluded: Bool) {
        guard isDesktopOccluded != isOccluded else {
            return
        }
        isDesktopOccluded = isOccluded
        desktopOcclusionHandler?(isOccluded)
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
