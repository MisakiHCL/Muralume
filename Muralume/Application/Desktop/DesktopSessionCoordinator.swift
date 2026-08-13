import Combine

private enum DesktopSessionTransitionError: Error {
    case statusMenuUnavailable
    case applicationPresenceUnavailable
}

enum DesktopSessionFailure: Equatable, Sendable {
    case playback(PlaybackFailure)
    case statusMenuUnavailable
}

@MainActor
final class DesktopSessionCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var transientFailure: DesktopSessionFailure?
    @Published private(set) var videoContentMode: DesktopVideoContentMode
    @Published private(set) var activeScene: DesktopScene?

    var didStopPlaybackHandler: (() -> Void)?
    var didEnterDesktopHandler: (() -> Void)?
    var didReturnToPlayerHandler: (() -> Void)?
    var canPlayNextProvider: (() -> Bool)?
    var playNextHandler: (() -> Void)?
    var playbackOrderProvider: (() -> PlaybackOrder)?
    var playbackModeProvider: (() -> PlaybackMode)?
    var canSetPlaybackOrderProvider: (() -> Bool)?
    var canSetPlaybackModeProvider: (() -> Bool)?
    var playbackOrderChangeHandler: ((PlaybackOrder) -> Void)?
    var playbackModeChangeHandler: ((PlaybackMode) -> Void)?
    var quitHandler: (() -> Void)?
    var independentSourceResolver:
        DesktopPlaybackOrchestrator.SourceResolver?

    var isTransitioning: Bool {
        if transitionTask != nil {
            return true
        }
        if case .switching = playback.presentation {
            return true
        }
        return false
    }

    private let playback: PlaybackCoordinator
    private let desktopHost: any DesktopHosting
    private let statusMenu: any DesktopStatusPresenting
    private let videoContentModeStore: any DesktopVideoContentModeStoring
    private let lifecycleMonitor: any SystemLifecycleMonitoring
    private let mainWindow: any MainWindowPresenting
    private let applicationPresence: any ApplicationPresenceControlling
    private let sceneController: DesktopSceneController?
    private let independentPlayback: DesktopPlaybackOrchestrator?
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var areDesktopEffectsConstrained = false
    private var isDesktopMonitoringEnabled = false
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        desktopHost: any DesktopHosting,
        statusMenu: any DesktopStatusPresenting,
        videoContentModeStore: any DesktopVideoContentModeStoring,
        lifecycleMonitor: any SystemLifecycleMonitoring,
        mainWindow: any MainWindowPresenting,
        applicationPresence: any ApplicationPresenceControlling,
        sceneController: DesktopSceneController? = nil,
        independentPlayback: DesktopPlaybackOrchestrator? = nil
    ) {
        self.playback = playback
        self.desktopHost = desktopHost
        self.statusMenu = statusMenu
        self.videoContentModeStore = videoContentModeStore
        videoContentMode = sceneController?.committedScene
            .defaultContentMode ?? videoContentModeStore.load()
        self.lifecycleMonitor = lifecycleMonitor
        self.mainWindow = mainWindow
        self.applicationPresence = applicationPresence
        self.sceneController = sceneController
        self.independentPlayback = independentPlayback

        playback.playbackFailureHandler = { [weak self] failure in
            self?.handlePlaybackFailure(failure)
        }
        configureStatusMenu()
        configureLifecycleMonitor()
        configureDesktopHost()
        configureIndependentPlayback()
        lifecycleMonitor.start()
    }

    func enterDesktop() {
        guard transitionTask == nil,
              playback.canPresentOnDesktop,
              !isShutDown else {
            return
        }

        transientFailure = nil
        let scene = sceneController?.committedScene
            ?? .legacy(contentMode: videoContentMode)
        activeScene = scene
        let preparation = desktopHost.prepare(scene: scene)
        transitionGeneration &+= 1
        let generation = transitionGeneration

        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                switch scene.mode {
                case .synchronized:
                    try await playback.transitionToDesktop(
                        preparation.synchronizedSurface
                    )
                case .perDisplay:
                    guard let independentPlayback,
                          let independentSourceResolver else {
                        throw PlaybackEngineError.cannotOpen
                    }
                    independentPlayback.setRate(playback.settings.rate)
                    independentPlayback.setPlaybackIntent(
                        playback.isPlaybackRequested ? .playing : .paused
                    )
                    try await independentPlayback.start(
                        assignments: scene.assignments,
                        surfaces: preparation.displaySurfaces,
                        sourceResolver: independentSourceResolver
                    )
                    // The player remains interactive while independent media
                    // prepares. Re-sample its latest intent and rate before
                    // detaching so a pause or speed change cannot drift.
                    independentPlayback.setRate(playback.settings.rate)
                    independentPlayback.setPlaybackIntent(
                        playback.isPlaybackRequested ? .playing : .paused
                    )
                    try await playback.transitionToIndependentDesktop()
                }
                try Task.checkCancellation()
                guard statusMenu.show() else {
                    throw DesktopSessionTransitionError.statusMenuUnavailable
                }
                desktopHost.reveal()
                guard applicationPresence.setMode(.menuBarOnly) else {
                    throw DesktopSessionTransitionError
                        .applicationPresenceUnavailable
                }
                mainWindow.hide()
                updateActiveState(true)
                didEnterDesktopHandler?()
            } catch is CancellationError {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        failure: nil,
                        generation: generation
                    )
                }
            } catch DesktopSessionTransitionError.statusMenuUnavailable {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        failure: .statusMenuUnavailable,
                        generation: generation
                    )
                }
            } catch let error as PlaybackEngineError {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        failure: .playback(Self.failure(for: error)),
                        generation: generation
                    )
                }
            } catch {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        failure: .playback(.surfaceTimeout),
                        generation: generation
                    )
                }
            }
            if isCurrentTransition(generation) {
                transitionTask = nil
                handleIndependentPlaybackStateChange()
            }
        }
    }

    func enterDesktopAndWait() async -> Bool {
        enterDesktop()
        guard let currentTransition = transitionTask else {
            return isActive && playback.presentation == .desktop
        }
        await currentTransition.value
        return isActive
            && playback.presentation == .desktop
            && !isTransitioning
    }

    func waitForTransitionToSettle() async {
        while let currentTransition = transitionTask {
            await currentTransition.value
        }
    }

    func returnToPlayer(revealWindow: Bool = true) {
        guard !isShutDown else {
            return
        }
        if transitionTask != nil {
            returnToPlayerFromCurrentTransition(
                revealWindow: revealWindow
            )
            return
        }
        guard isActive else {
            return
        }

        transientFailure = nil
        if revealWindow {
            guard applicationPresence.setMode(.standard) else {
                transientFailure = .playback(.surfaceTimeout)
                return
            }
        }

        playback.restorePlayerWindow()
        if revealWindow {
            mainWindow.prepareForReturn()
        }
        beginPlayerReturnTransition(revealWindow: revealWindow)
    }

    private func beginPlayerReturnTransition(revealWindow: Bool) {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await playback.transitionToPlayer()
                try Task.checkCancellation()
                if revealWindow {
                    mainWindow.show()
                }
                await independentPlayback?.stopAndDrain()
                try Task.checkCancellation()
                guard isCurrentTransition(generation) else {
                    throw CancellationError()
                }
                desktopHost.close()
                statusMenu.remove()
                activeScene = nil
                updateActiveState(false)
                didReturnToPlayerHandler?()
            } catch is CancellationError {
                // A newer stop or quit intent owns the final presentation state.
            } catch {
                if isCurrentTransition(generation) {
                    _ = applicationPresence.setMode(.menuBarOnly)
                    mainWindow.hideAfterFailedReturn()
                    desktopHost.reassertDesktopPlacement()
                    updateActiveState(true)
                    transientFailure = .playback(.surfaceTimeout)
                }
            }
            if isCurrentTransition(generation) {
                transitionTask = nil
            }
        }
    }

    func dismissMainWindow() {
        guard !isShutDown else {
            return
        }

        transientFailure = nil
        let wasDesktopPresentationRelevant =
            isActive
            || isTransitioning
            || playback.presentation == .desktop
        invalidateTransition()
        playback.dismissPlayerWindow()

        if wasDesktopPresentationRelevant {
            let restoredStandardPresence =
                applicationPresence.setMode(.standard)
            Task { [independentPlayback] in
                await independentPlayback?.stopAndDrain()
            }
            desktopHost.close()
            if restoredStandardPresence {
                statusMenu.remove()
            }
            activeScene = nil
            updateActiveState(!restoredStandardPresence)
        }

        mainWindow.dismiss()
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        guard contentMode != videoContentMode, !isShutDown else {
            return
        }
        videoContentMode = contentMode
        videoContentModeStore.save(contentMode)
        sceneController?.updateSynchronizedContentMode(contentMode)
        desktopHost.setVideoContentMode(contentMode)
    }

    func applyLegacyContentModeIfNeeded(
        _ contentMode: DesktopVideoContentMode
    ) {
        if let sceneController {
            sceneController.applyLegacyContentModeIfNeeded(contentMode)
            let resolvedMode = sceneController.committedScene
                .defaultContentMode
            guard resolvedMode != videoContentMode else {
                return
            }
            videoContentMode = resolvedMode
            videoContentModeStore.save(resolvedMode)
            desktopHost.setVideoContentMode(resolvedMode)
            return
        }
        setVideoContentMode(contentMode)
    }

    func stop() {
        guard isActive, !isShutDown else {
            return
        }

        invalidateTransition()
        Task { [independentPlayback] in
            await independentPlayback?.stopAndDrain()
        }
        playback.stop()
        let restoredStandardPresence = applicationPresence.setMode(.standard)
        mainWindow.show()
        desktopHost.close()
        if restoredStandardPresence {
            statusMenu.remove()
        }
        activeScene = nil
        updateActiveState(!restoredStandardPresence)
        didStopPlaybackHandler?()
    }

    /// Drains independent desktop consumers before media-session security
    /// scopes are closed during application shutdown.
    func prepareForMediaScopeShutdown() async {
        await independentPlayback?.stopAndDrain()
    }

    /// Drains only displays that consume the supplied library items. The
    /// scene assignments remain intact, but those items stay suppressed until
    /// the next independent desktop start establishes a fresh source scope.
    func drainMediaItems(_ itemIDs: Set<LibraryMediaItem.ID>) async {
        guard !itemIDs.isEmpty else {
            return
        }
        await independentPlayback?.stopAndDrain(itemIDs: itemIDs)
    }

    var activeIndependentMediaItemIDs: Set<LibraryMediaItem.ID> {
        independentPlayback?.activeMediaItemIDs ?? []
    }

    func dismissTransientFailure() {
        transientFailure = nil
    }

    func shutdown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true

        invalidateTransition()
        updateActiveState(false)
        lifecycleMonitor.stop()
        lifecycleMonitor.suspensionHandler = nil
        lifecycleMonitor.energyConstraintsHandler = nil
        statusMenu.remove()
        independentPlayback?.shutdown()
        Task { [independentPlayback] in
            await independentPlayback?.stopAndDrain()
        }
        playback.shutdown()
        desktopHost.close()
        activeScene = nil
        desktopHost.desktopOcclusionHandler = nil
    }

    private func configureStatusMenu() {
        statusMenu.stateProvider = { [weak self] in
            guard let self else {
                let defaultOrder = AppPreferences.defaultValue.playbackOrder
                return DesktopStatusState(
                    sourceName: "",
                    isPlaying: false,
                    isTransitioning: false,
                    canPlayNext: false,
                    playbackOrder: defaultOrder,
                    playbackRepeatBehavior:
                        AppPreferences.defaultValue.playbackRepeatBehavior,
                    canSetPlaybackOrder: false,
                    playbackRate: PlaybackPolicy.defaultRate,
                    videoContentMode: .defaultValue
                )
            }
            let mode = playbackModeProvider?()
            let fallbackOrder = playbackOrderProvider?()
                ?? AppPreferences.defaultValue.playbackOrder
            let activeScene = self.activeScene
            let isIndependent = activeScene?.mode == .perDisplay
            return DesktopStatusState(
                sourceName: playback.source?.displayName ?? "",
                isPlaying: playback.isPlaybackRequested,
                isTransitioning: isTransitioning,
                canPlayNext:
                    !isIndependent && canPlayNextProvider?() == true,
                playbackOrder: mode.flatMap { mode in
                    switch mode {
                    case .ordered:
                        .ordered
                    case .shuffled:
                        .shuffled
                    case .repeatCurrent:
                        nil
                    }
                } ?? fallbackOrder,
                playbackRepeatBehavior: mode == .repeatCurrent
                    ? .currentItem
                    : .queue,
                canSetPlaybackOrder:
                    !isIndependent
                        && (canSetPlaybackModeProvider?()
                            ?? (canSetPlaybackOrderProvider?() == true)),
                playbackRate: playback.settings.rate,
                videoContentMode: videoContentMode,
                sceneMode: activeScene?.mode ?? .synchronized,
                enabledDisplayCount: activeScene.map {
                    enabledConnectedDisplayCount(in: $0)
                } ?? 1,
                failedDisplayCount: isIndependent
                    ? independentPlayback?.failedDisplayCount ?? 0
                    : 0
            )
        }
        statusMenu.togglePlaybackHandler = { [weak self] in
            self?.togglePlayback()
        }
        statusMenu.playNextHandler = { [weak self] in
            self?.playNext()
        }
        statusMenu.setPlaybackOrderHandler = { [weak self] order in
            self?.setPlaybackOrder(order)
        }
        statusMenu.setPlaybackModeHandler = { [weak self] mode in
            self?.setPlaybackMode(mode)
        }
        statusMenu.setPlaybackRateHandler = { [weak self] rate in
            self?.setPlaybackRate(rate)
        }
        statusMenu.returnToPlayerHandler = { [weak self] in
            self?.returnToPlayer()
        }
        statusMenu.setVideoContentModeHandler = { [weak self] contentMode in
            self?.setVideoContentMode(contentMode)
        }
        statusMenu.quitHandler = { [weak self] in
            self?.quitHandler?()
        }
    }

    private func configureLifecycleMonitor() {
        lifecycleMonitor.suspensionHandler = { [weak self] reason, suspended in
            guard let self, !isShutDown else {
                return
            }
            playback.setSuspended(suspended, for: reason)
            independentPlayback?.setSuspended(
                suspended,
                for: reason
            )
        }
        lifecycleMonitor.energyConstraintsHandler = {
            [weak self] constraints in
            self?.applyEnergyConstraints(constraints)
        }
    }

    private func configureDesktopHost() {
        desktopHost.desktopOcclusionHandler = { [weak self] isOccluded in
            guard let self, !isShutDown else {
                return
            }
            playback.setSuspended(isOccluded, for: .desktopOccluded)
            independentPlayback?.setSuspended(
                isOccluded,
                for: .desktopOccluded
            )
        }
        desktopHost.setDisplaySurfaceEventHandler { [weak self] event in
            guard let self,
                  !isShutDown,
                  activeScene?.mode == .perDisplay else {
                return
            }
            switch event {
            case let .didAdd(displayID, surface):
                independentPlayback?.addSurface(
                    surface,
                    for: displayID
                )
            case let .willRemove(displayID):
                independentPlayback?.removeSurface(for: displayID)
            }
        }
    }

    private func configureIndependentPlayback() {
        independentPlayback?.playbackStateDidChangeHandler = { [weak self] in
            self?.handleIndependentPlaybackStateChange()
        }
    }

    private func handleIndependentPlaybackStateChange() {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              activeScene?.mode == .perDisplay,
              let failure = independentPlayback?.terminalFailure else {
            return
        }

        transientFailure = .playback(failure)
        guard applicationPresence.setMode(.standard) else {
            return
        }
        playback.restorePlayerWindow()
        mainWindow.prepareForReturn()
        beginPlayerReturnTransition(revealWindow: true)
    }

    private func applyEnergyConstraints(
        _ constraints: Set<SystemEnergyConstraintReason>
    ) {
        guard !isShutDown else {
            return
        }
        let shouldConstrainEffects = !constraints.isEmpty
        guard areDesktopEffectsConstrained != shouldConstrainEffects else {
            return
        }
        areDesktopEffectsConstrained = shouldConstrainEffects
        desktopHost.setEnergyConstrained(shouldConstrainEffects)
    }

    private func updateActiveState(_ isActive: Bool) {
        self.isActive = isActive
        let shouldMonitorDesktop = isActive
            && playback.presentation == .desktop
        guard isDesktopMonitoringEnabled != shouldMonitorDesktop else {
            return
        }
        isDesktopMonitoringEnabled = shouldMonitorDesktop
        lifecycleMonitor.setDesktopMonitoringActive(shouldMonitorDesktop)
    }

    private func handlePlaybackFailure(_ failure: PlaybackFailure) {
        guard isActive else {
            return
        }
        transientFailure = .playback(failure)
        invalidateTransition()
        let restoredStandardPresence = applicationPresence.setMode(.standard)
        mainWindow.show()
        Task { [independentPlayback] in
            await independentPlayback?.stopAndDrain()
        }
        desktopHost.close()
        if restoredStandardPresence {
            statusMenu.remove()
        }
        activeScene = nil
        updateActiveState(!restoredStandardPresence)
        didStopPlaybackHandler?()
    }

    private func playNext() {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              activeScene?.mode != .perDisplay,
              canPlayNextProvider?() == true else {
            return
        }
        playNextHandler?()
    }

    private func togglePlayback() {
        guard isActive, !isTransitioning, !isShutDown else {
            return
        }
        let intent: PlaybackIntent = playback.isPlaybackRequested
            ? .paused
            : .playing
        playback.setPlaybackIntent(intent)
        independentPlayback?.setPlaybackIntent(intent)
    }

    private func setPlaybackOrder(_ order: PlaybackOrder) {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              activeScene?.mode != .perDisplay,
              canSetPlaybackOrderProvider?() == true else {
            return
        }
        playbackOrderChangeHandler?(order)
    }

    private func setPlaybackMode(_ mode: PlaybackMode) {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              activeScene?.mode != .perDisplay,
              canSetPlaybackModeProvider?()
                ?? (canSetPlaybackOrderProvider?() == true) else {
            return
        }
        if let playbackModeChangeHandler {
            playbackModeChangeHandler(mode)
            return
        }
        switch mode {
        case .ordered:
            playbackOrderChangeHandler?(.ordered)
        case .shuffled:
            playbackOrderChangeHandler?(.shuffled)
        case .repeatCurrent:
            break
        }
    }

    private func setPlaybackRate(_ rate: PlaybackRate) {
        guard isActive,
              !isTransitioning,
              !isShutDown else {
            return
        }
        playback.setRate(rate)
        independentPlayback?.setRate(rate)
    }

    private func enabledConnectedDisplayCount(
        in scene: DesktopScene
    ) -> Int {
        guard let sceneController else {
            return max(
                scene.assignments.filter(\.isEnabled).count,
                1
            )
        }
        return sceneController.connectedDisplays.filter { display in
            if let assignment = scene.assignment(for: display.id) {
                return assignment.isEnabled
            }
            return scene.mode == .synchronized
                && scene.appliesToAllConnectedDisplays
        }.count
    }

    private func recoverFromFailedDesktopEntry(
        failure: DesktopSessionFailure?,
        generation: UInt64
    ) async {
        guard !isShutDown, isCurrentTransition(generation) else {
            return
        }

        switch playback.presentation {
        case .desktop, .switching(_, .desktop):
            do {
                try await playback.transitionToPlayer()
            } catch {
                guard !isShutDown, isCurrentTransition(generation) else {
                    return
                }
                playback.stop()
                didStopPlaybackHandler?()
            }
        case .player, .terminating, .switching(_, .player):
            break
        }

        guard !isShutDown, isCurrentTransition(generation) else {
            return
        }
        let restoredStandardPresence = applicationPresence.setMode(.standard)
        if restoredStandardPresence {
            statusMenu.remove()
        }
        await independentPlayback?.stopAndDrain()
        guard !isShutDown, isCurrentTransition(generation) else {
            return
        }
        desktopHost.close()
        mainWindow.show()
        activeScene = nil
        updateActiveState(!restoredStandardPresence)
        transientFailure = failure
    }

    private func returnToPlayerFromCurrentTransition(
        revealWindow: Bool
    ) {
        switch playback.presentation {
        case .player:
            cancelDesktopEntryBeforePlaybackTransition(
                revealWindow: revealWindow
            )
            return
        case .switching(_, .player), .terminating:
            return
        case .desktop, .switching(_, .desktop):
            break
        }

        transientFailure = nil
        if revealWindow {
            guard applicationPresence.setMode(.standard) else {
                transientFailure = .playback(.surfaceTimeout)
                return
            }
        }

        invalidateTransition()
        playback.restorePlayerWindow()
        if revealWindow {
            mainWindow.prepareForReturn()
        }
        beginPlayerReturnTransition(revealWindow: revealWindow)
    }

    private func cancelDesktopEntryBeforePlaybackTransition(
        revealWindow: Bool
    ) {
        transientFailure = nil
        invalidateTransition()
        let generation = transitionGeneration
        let cleanupTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if isCurrentTransition(generation) {
                    transitionTask = nil
                }
            }
            guard !Task.isCancelled,
                  isCurrentTransition(generation) else {
                return
            }
            await independentPlayback?.stopAndDrain()
            guard !Task.isCancelled,
                  isCurrentTransition(generation) else {
                return
            }
            desktopHost.close()
            activeScene = nil
            updateActiveState(false)
            if revealWindow {
                guard applicationPresence.setMode(.standard) else {
                    transientFailure = .playback(.surfaceTimeout)
                    updateActiveState(true)
                    return
                }
                statusMenu.remove()
                playback.restorePlayerWindow()
                mainWindow.prepareForReturn()
                mainWindow.show()
            }
            didReturnToPlayerHandler?()
        }
        transitionTask = cleanupTask
    }

    private func invalidateTransition() {
        transitionGeneration &+= 1
        transitionTask?.cancel()
        transitionTask = nil
    }

    private func isCurrentTransition(_ generation: UInt64) -> Bool {
        transitionGeneration == generation
    }

    private static func failure(
        for error: PlaybackEngineError
    ) -> PlaybackFailure {
        switch error {
        case .unsupported:
            .unsupported
        case .surfaceTimeout:
            .surfaceTimeout
        case .cannotOpen, .incompatibleSurface, .superseded:
            .cannotOpen
        }
    }
}
