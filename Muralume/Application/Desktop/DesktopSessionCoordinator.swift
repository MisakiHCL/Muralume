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
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        desktopHost: any DesktopHosting,
        statusMenu: any DesktopStatusPresenting,
        videoContentModeStore: any DesktopVideoContentModeStoring,
        lifecycleMonitor: any SystemLifecycleMonitoring,
        mainWindow: any MainWindowPresenting,
        applicationPresence: any ApplicationPresenceControlling
    ) {
        self.playback = playback
        self.desktopHost = desktopHost
        self.statusMenu = statusMenu
        self.videoContentModeStore = videoContentModeStore
        videoContentMode = videoContentModeStore.load()
        self.lifecycleMonitor = lifecycleMonitor
        self.mainWindow = mainWindow
        self.applicationPresence = applicationPresence

        playback.playbackFailureHandler = { [weak self] failure in
            self?.handlePlaybackFailure(failure)
        }
        configureStatusMenu()
        configureLifecycleMonitor()
        lifecycleMonitor.start()
    }

    func enterDesktop() {
        guard transitionTask == nil,
              playback.canPresentOnDesktop,
              !isShutDown else {
            return
        }

        transientFailure = nil
        let surface = desktopHost.prepare(contentMode: videoContentMode)
        transitionGeneration &+= 1
        let generation = transitionGeneration

        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await playback.transitionToDesktop(surface)
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
                isActive = true
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
                desktopHost.close()
                statusMenu.remove()
                isActive = false
                didReturnToPlayerHandler?()
            } catch is CancellationError {
                // A newer stop or quit intent owns the final presentation state.
            } catch {
                if isCurrentTransition(generation) {
                    _ = applicationPresence.setMode(.menuBarOnly)
                    mainWindow.hideAfterFailedReturn()
                    desktopHost.reassertDesktopPlacement()
                    isActive = true
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
            desktopHost.close()
            if restoredStandardPresence {
                statusMenu.remove()
            }
            isActive = !restoredStandardPresence
        }

        mainWindow.dismiss()
    }

    func setVideoContentMode(_ contentMode: DesktopVideoContentMode) {
        guard contentMode != videoContentMode, !isShutDown else {
            return
        }
        videoContentMode = contentMode
        videoContentModeStore.save(contentMode)
        desktopHost.setVideoContentMode(contentMode)
    }

    func stop() {
        guard isActive, !isShutDown else {
            return
        }

        invalidateTransition()
        playback.stop()
        let restoredStandardPresence = applicationPresence.setMode(.standard)
        mainWindow.show()
        desktopHost.close()
        if restoredStandardPresence {
            statusMenu.remove()
        }
        isActive = !restoredStandardPresence
        didStopPlaybackHandler?()
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
        lifecycleMonitor.stop()
        statusMenu.remove()
        playback.shutdown()
        desktopHost.close()
        isActive = false
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
            return DesktopStatusState(
                sourceName: playback.source?.displayName ?? "",
                isPlaying: playback.isPlaybackRequested,
                isTransitioning: isTransitioning,
                canPlayNext: canPlayNextProvider?() == true,
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
                    canSetPlaybackModeProvider?()
                        ?? (canSetPlaybackOrderProvider?() == true),
                playbackRate: playback.settings.rate,
                videoContentMode: videoContentMode
            )
        }
        statusMenu.togglePlaybackHandler = { [weak self] in
            self?.playback.togglePlayback()
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
            self?.playback.setSuspended(suspended, for: reason)
        }
        lifecycleMonitor.energyConstrainedHandler = {
            [weak self] isConstrained in
            self?.desktopHost.setEnergyConstrained(isConstrained)
        }
    }

    private func handlePlaybackFailure(_ failure: PlaybackFailure) {
        guard isActive else {
            return
        }
        transientFailure = .playback(failure)
        invalidateTransition()
        let restoredStandardPresence = applicationPresence.setMode(.standard)
        mainWindow.show()
        desktopHost.close()
        if restoredStandardPresence {
            statusMenu.remove()
        }
        isActive = !restoredStandardPresence
        didStopPlaybackHandler?()
    }

    private func playNext() {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              canPlayNextProvider?() == true else {
            return
        }
        playNextHandler?()
    }

    private func setPlaybackOrder(_ order: PlaybackOrder) {
        guard isActive,
              !isTransitioning,
              !isShutDown,
              canSetPlaybackOrderProvider?() == true else {
            return
        }
        playbackOrderChangeHandler?(order)
    }

    private func setPlaybackMode(_ mode: PlaybackMode) {
        guard isActive,
              !isTransitioning,
              !isShutDown,
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
    }

    private func recoverFromFailedDesktopEntry(
        failure: DesktopSessionFailure?,
        generation: UInt64
    ) async {
        guard !isShutDown, isCurrentTransition(generation) else {
            desktopHost.close()
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
        desktopHost.close()
        mainWindow.show()
        isActive = !restoredStandardPresence
        transientFailure = failure
    }

    private func returnToPlayerFromCurrentTransition(
        revealWindow: Bool
    ) {
        switch playback.presentation {
        case .switching(_, .player), .player, .terminating:
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

    private func invalidateTransition() {
        transitionGeneration &+= 1
        transitionTask?.cancel()
        transitionTask = nil
    }

    private func isCurrentTransition(_ generation: UInt64) -> Bool {
        transitionGeneration == generation
    }
}
