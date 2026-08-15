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
    let visibleFrame: NSRect
    let screen: NSScreen?

    init(
        id: CGDirectDisplayID,
        frame: NSRect,
        visibleFrame: NSRect? = nil,
        screen: NSScreen? = nil
    ) {
        self.id = MacDesktopDisplayID(rawValue: id)
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
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
        let occlusionProbes: [DesktopOcclusionProbeWindow]
        let surface: DesktopPlayerLayerSurfaceView
        var frame: NSRect
        var effectiveDesktopRect: NSRect
    }

    private(set) var surface: DesktopPlayerLayerSurfaceGroup?

    var desktopOcclusionHandler: ((Bool) -> Void)? {
        didSet {
            desktopOcclusionHandler?(isDesktopOccluded)
        }
    }

    var desktopVisibilityHandler: (
        ([DesktopDisplayID: DesktopVisibilityState]) -> Void
    )? {
        didSet {
            desktopVisibilityHandler?(desktopVisibilityStates)
        }
    }

    private(set) var isDesktopOccluded = false
    var isDesktopOcclusionDebouncePending: Bool {
        !occlusionDebounceTasks.isEmpty
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

    var hostedProbeWindows: [
        MacDesktopDisplayID: [DesktopOcclusionProbeWindow]
    ] {
        hostedDisplays.mapValues(\.occlusionProbes)
    }

    private(set) var desktopVisibilityStates: [
        DesktopDisplayID: DesktopVisibilityState
    ] = [:]

    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let displaysProvider: () -> [MacDesktopDisplay]
    private let isSurfaceReady: (DesktopPlayerLayerSurfaceView) -> Bool
    private let isProbeVisible: (DesktopOcclusionProbeWindow) -> Bool
    private let displayIdentityResolver: (
        MacDesktopDisplay
    ) -> DesktopDisplayID
    private let emptyTopologyGracePeriodNanoseconds: UInt64
    private let occlusionDebounceNanoseconds: UInt64
    private let visibilityRecoveryDebounceNanoseconds: UInt64
    private let visibilityRefreshIntervalNanoseconds: UInt64
    private var hostedDisplays: [MacDesktopDisplayID: HostedDisplay] = [:]
    private var displayRevealTasks: [
        MacDesktopDisplayID: Task<Void, Never>
    ] = [:]
    private var emptyTopologyTask: Task<Void, Never>?
    private var occlusionDebounceTasks: [
        MacDesktopDisplayID: Task<Void, Never>
    ] = [:]
    private var visibilityRecoveryTasks: [
        MacDesktopDisplayID: Task<Void, Never>
    ] = [:]
    private var visibilityRefreshTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowOcclusionObservers: [
        MacDesktopDisplayID: [NSObjectProtocol]
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
        isProbeVisible: @escaping (DesktopOcclusionProbeWindow) -> Bool = {
            $0.occlusionState.contains(.visible)
        },
        displayIdentityResolver: @escaping (
            MacDesktopDisplay
        ) -> DesktopDisplayID = {
            MacDesktopDisplayIdentityResolver.stableID(
                for: $0.id.rawValue
            )
        },
        emptyTopologyGracePeriodNanoseconds: UInt64 =
            DesktopDisplayTopologyPolicy.emptyTopologyGracePeriodNanoseconds,
        occlusionDebounceNanoseconds: UInt64 =
            DesktopOcclusionPolicy.debounceNanoseconds,
        visibilityRecoveryDebounceNanoseconds: UInt64 =
            DesktopOcclusionPolicy.recoveryDebounceNanoseconds,
        visibilityRefreshIntervalNanoseconds: UInt64 =
            DesktopOcclusionPolicy.refreshIntervalNanoseconds
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        self.displaysProvider = displaysProvider
        self.isSurfaceReady = isSurfaceReady
        self.isProbeVisible = isProbeVisible
        self.displayIdentityResolver = displayIdentityResolver
        self.emptyTopologyGracePeriodNanoseconds =
            emptyTopologyGracePeriodNanoseconds
        self.occlusionDebounceNanoseconds = occlusionDebounceNanoseconds
        self.visibilityRecoveryDebounceNanoseconds =
            visibilityRecoveryDebounceNanoseconds
        self.visibilityRefreshIntervalNanoseconds =
            visibilityRefreshIntervalNanoseconds
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
        refreshDesktopVisibilityStates()
        startVisibilityRefreshLoopIfNeeded()
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
        hostedDisplays.values.forEach(Self.reassertProbePlacement)
    }

    func close() {
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        windowOcclusionObservers.values
            .joined()
            .forEach(notificationCenter.removeObserver)
        windowOcclusionObservers.removeAll()
        cancelPendingTopologyWork()
        cancelAllOcclusionDebounces()
        cancelAllVisibilityRecoveries()
        visibilityRefreshTask?.cancel()
        visibilityRefreshTask = nil
        isRevealed = false
        surface?.replaceDisplaySurfaces([])
        surface?.connect(to: nil)
        surface = nil
        hostedDisplays.values.forEach(Self.tearDown)
        hostedDisplays.removeAll()
        desktopVisibilityStates.removeAll()
        isDesktopOccluded = false
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
                    self?.refreshDesktopVisibilityStates()
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
            cancelOcclusionDebounce(for: displayID)
            cancelVisibilityRecovery(for: displayID)
            removeOcclusionObservers(for: displayID)
            if let removedDisplay = hostedDisplays.removeValue(
                forKey: displayID
            ) {
                desktopVisibilityStates[removedDisplay.stableID] = nil
                displaySurfaceEventHandler?(
                    .willRemove(displayID: removedDisplay.stableID)
                )
                removedDisplays.append(removedDisplay)
            }
        }

        for (displayID, display) in displays {
            if var hostedDisplay = hostedDisplays[displayID] {
                hostedDisplay.frame = display.frame
                hostedDisplay.effectiveDesktopRect = Self
                    .effectiveDesktopRect(for: display)
                hostedDisplay.window.setFrame(display.frame, display: true)
                Self.updateProbeFrames(
                    for: hostedDisplay.occlusionProbes,
                    effectiveDesktopRect: hostedDisplay.effectiveDesktopRect
                )
                hostedDisplays[displayID] = hostedDisplay
            } else {
                let hostedDisplay = makeHostedDisplay(for: display)
                hostedDisplays[displayID] = hostedDisplay
                installOcclusionObservers(
                    for: displayID,
                    windows: hostedDisplay.occlusionProbes
                )
                desktopVisibilityStates[hostedDisplay.stableID] = .visible
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
        publishDesktopVisibilitySnapshot()
        refreshDesktopVisibilityStates()
    }

    private func makeHostedDisplay(
        for display: MacDesktopDisplay
    ) -> HostedDisplay {
        let stableID = stableDisplayID(for: display)
        let effectiveDesktopRect = Self.effectiveDesktopRect(for: display)
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

        let occlusionProbes = DesktopOcclusionGeometry.probeRects(
            in: effectiveDesktopRect
        ).map { probeRect in
            let probe = DesktopOcclusionProbeWindow(
                contentRect: probeRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: display.screen
            )
            probe.backgroundColor = .clear
            probe.collectionBehavior = window.collectionBehavior
            probe.hasShadow = false
            probe.hidesOnDeactivate = false
            probe.ignoresMouseEvents = true
            probe.isExcludedFromWindowsMenu = true
            probe.isMovable = false
            probe.isOpaque = false
            probe.isReleasedWhenClosed = false
            probe.level = Self.desktopVideoLevel
            probe.order(.above, relativeTo: window.windowNumber)
            return probe
        }

        return HostedDisplay(
            stableID: stableID,
            window: window,
            occlusionProbes: occlusionProbes,
            surface: surface,
            frame: display.frame,
            effectiveDesktopRect: effectiveDesktopRect
        )
    }

    private static func effectiveDesktopRect(
        for display: MacDesktopDisplay
    ) -> NSRect {
        if let screen = display.screen {
            return DesktopOcclusionGeometry.effectiveDesktopRect(for: screen)
        }
        return DesktopOcclusionGeometry.effectiveDesktopRect(
            visibleFrame: display.visibleFrame,
            screenFrame: display.frame
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
        displayIdentityResolver(display)
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
            refreshDesktopVisibilityStates()
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
                        self.refreshDesktopVisibilityStates()
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

    private func installOcclusionObservers(
        for displayID: MacDesktopDisplayID,
        windows: [DesktopOcclusionProbeWindow]
    ) {
        removeOcclusionObservers(for: displayID)
        windowOcclusionObservers[displayID] = windows.map { window in
            notificationCenter.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDesktopVisibilityStates()
                }
            }
        }
    }

    private func removeOcclusionObservers(
        for displayID: MacDesktopDisplayID
    ) {
        guard let observers = windowOcclusionObservers.removeValue(
            forKey: displayID
        ) else {
            return
        }
        observers.forEach(notificationCenter.removeObserver)
    }

    private func refreshDesktopVisibilityStates() {
        guard isRevealed, !hostedDisplays.isEmpty else {
            cancelAllOcclusionDebounces()
            cancelAllVisibilityRecoveries()
            for hostedDisplay in hostedDisplays.values {
                publishVisibility(
                    .visible,
                    for: hostedDisplay.stableID
                )
            }
            return
        }

        for (displayID, hostedDisplay) in hostedDisplays {
            guard hostedDisplay.window.alphaValue
                    >= DesktopOcclusionPolicy.revealedWindowAlphaThreshold else {
                cancelOcclusionDebounce(for: displayID)
                cancelVisibilityRecovery(for: displayID)
                publishVisibility(.visible, for: hostedDisplay.stableID)
                continue
            }

            if !isEffectivelyOccluded(hostedDisplay) {
                cancelOcclusionDebounce(for: displayID)
                scheduleVisibilityRecoveryIfNeeded(
                    for: displayID,
                    stableID: hostedDisplay.stableID
                )
            } else {
                cancelVisibilityRecovery(for: displayID)
                scheduleOcclusionDebounceIfNeeded(
                    for: displayID,
                    stableID: hostedDisplay.stableID
                )
            }
        }
    }

    private func isEffectivelyOccluded(
        _ hostedDisplay: HostedDisplay
    ) -> Bool {
        DesktopOcclusionSampling.isEffectivelyOccluded(
            probeVisibility: hostedDisplay.occlusionProbes.map(
                isProbeVisible
            )
        )
    }

    private func startVisibilityRefreshLoopIfNeeded() {
        guard visibilityRefreshTask == nil else {
            return
        }
        let intervalNanoseconds = visibilityRefreshIntervalNanoseconds
        visibilityRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
                guard let self, isRevealed, surface != nil else {
                    return
                }
                refreshDesktopVisibilityStates()
            }
        }
    }

    private func scheduleOcclusionDebounceIfNeeded(
        for displayID: MacDesktopDisplayID,
        stableID: DesktopDisplayID
    ) {
        guard desktopVisibilityStates[stableID] != .occluded,
              occlusionDebounceTasks[displayID] == nil else {
            return
        }
        let debounceNanoseconds = occlusionDebounceNanoseconds
        occlusionDebounceTasks[displayID] = Task {
            @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  let hostedDisplay = hostedDisplays[displayID],
                  hostedDisplay.stableID == stableID else {
                return
            }
            occlusionDebounceTasks[displayID] = nil
            guard isRevealed,
                  hostedDisplay.window.alphaValue
                    >= DesktopOcclusionPolicy.revealedWindowAlphaThreshold,
                  isEffectivelyOccluded(hostedDisplay) else {
                return
            }
            publishVisibility(.occluded, for: stableID)
        }
    }

    private func cancelOcclusionDebounce(
        for displayID: MacDesktopDisplayID
    ) {
        occlusionDebounceTasks.removeValue(forKey: displayID)?.cancel()
    }

    private func cancelAllOcclusionDebounces() {
        occlusionDebounceTasks.values.forEach { $0.cancel() }
        occlusionDebounceTasks.removeAll()
    }

    private func scheduleVisibilityRecoveryIfNeeded(
        for displayID: MacDesktopDisplayID,
        stableID: DesktopDisplayID
    ) {
        guard desktopVisibilityStates[stableID] == .occluded,
              visibilityRecoveryTasks[displayID] == nil else {
            return
        }
        let debounceNanoseconds = visibilityRecoveryDebounceNanoseconds
        visibilityRecoveryTasks[displayID] = Task {
            @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  let hostedDisplay = hostedDisplays[displayID],
                  hostedDisplay.stableID == stableID else {
                return
            }
            visibilityRecoveryTasks[displayID] = nil
            guard isRevealed,
                  hostedDisplay.window.alphaValue
                    >= DesktopOcclusionPolicy.revealedWindowAlphaThreshold,
                  !isEffectivelyOccluded(hostedDisplay) else {
                return
            }
            publishVisibility(.visible, for: stableID)
        }
    }

    private func cancelVisibilityRecovery(
        for displayID: MacDesktopDisplayID
    ) {
        visibilityRecoveryTasks.removeValue(forKey: displayID)?.cancel()
    }

    private func cancelAllVisibilityRecoveries() {
        visibilityRecoveryTasks.values.forEach { $0.cancel() }
        visibilityRecoveryTasks.removeAll()
    }

    private func publishVisibility(
        _ state: DesktopVisibilityState,
        for displayID: DesktopDisplayID
    ) {
        guard desktopVisibilityStates[displayID] != state else {
            return
        }
        desktopVisibilityStates[displayID] = state
        publishDesktopVisibilitySnapshot()
    }

    private func publishDesktopVisibilitySnapshot() {
        let wasDesktopOccluded = isDesktopOccluded
        isDesktopOccluded = !desktopVisibilityStates.isEmpty
            && desktopVisibilityStates.values.allSatisfy { $0 == .occluded }
        desktopVisibilityHandler?(desktopVisibilityStates)
        if wasDesktopOccluded != isDesktopOccluded {
            desktopOcclusionHandler?(isDesktopOccluded)
        }
    }

    private static func reassertPlacement(
        _ hostedDisplay: HostedDisplay
    ) {
        hostedDisplay.window.setFrame(hostedDisplay.frame, display: true)
        hostedDisplay.window.level = desktopVideoLevel
        hostedDisplay.window.ignoresMouseEvents = true
        hostedDisplay.window.orderFrontRegardless()
    }

    private static func reassertProbePlacement(
        _ hostedDisplay: HostedDisplay
    ) {
        updateProbeFrames(
            for: hostedDisplay.occlusionProbes,
            effectiveDesktopRect: hostedDisplay.effectiveDesktopRect
        )
        hostedDisplay.occlusionProbes.forEach { probe in
            probe.level = desktopVideoLevel
            probe.ignoresMouseEvents = true
            probe.order(
                .above,
                relativeTo: hostedDisplay.window.windowNumber
            )
        }
    }

    private static func updateProbeFrames(
        for probes: [DesktopOcclusionProbeWindow],
        effectiveDesktopRect: NSRect
    ) {
        let frames = DesktopOcclusionGeometry.probeRects(
            in: effectiveDesktopRect
        )
        for (probe, frame) in zip(probes, frames) {
            probe.setFrame(frame, display: true)
        }
    }

    private static func tearDown(_ hostedDisplay: HostedDisplay) {
        hostedDisplay.surface.connect(to: nil)
        hostedDisplay.window.orderOut(nil)
        hostedDisplay.window.contentView = nil
        hostedDisplay.window.close()
        hostedDisplay.occlusionProbes.forEach { probe in
            probe.orderOut(nil)
            probe.close()
        }
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
                visibleFrame: screen.visibleFrame,
                screen: screen
            )
        }
    }
}
