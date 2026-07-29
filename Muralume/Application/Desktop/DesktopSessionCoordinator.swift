import Combine

private enum DesktopSessionTransitionError: Error {
    case applicationPresenceUnavailable
}

@MainActor
final class DesktopSessionCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var transientFailure: PlaybackFailure?
    @Published private(set) var videoContentMode: DesktopVideoContentMode

    var didStopPlaybackHandler: (() -> Void)?
    var canPlayNextProvider: (() -> Bool)?
    var playNextHandler: (() -> Void)?
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
                desktopHost.reveal()
                statusMenu.show()
                guard applicationPresence.setMode(.menuBarOnly) else {
                    throw DesktopSessionTransitionError
                        .applicationPresenceUnavailable
                }
                mainWindow.hide()
                isActive = true
            } catch is CancellationError {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        reportFailure: false,
                        generation: generation
                    )
                }
            } catch {
                if isCurrentTransition(generation) {
                    await recoverFromFailedDesktopEntry(
                        reportFailure: true,
                        generation: generation
                    )
                }
            }
            if isCurrentTransition(generation) {
                transitionTask = nil
            }
        }
    }

    func returnToPlayer() {
        guard !isShutDown else {
            return
        }
        if transitionTask != nil {
            recoverPlayerWindowFromTransition()
            return
        }
        guard isActive else {
            return
        }

        transientFailure = nil
        guard applicationPresence.setMode(.standard) else {
            transientFailure = .surfaceTimeout
            return
        }

        playback.restorePlayerWindow()
        mainWindow.prepareForReturn()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await playback.transitionToPlayer()
                try Task.checkCancellation()
                mainWindow.show()
                desktopHost.close()
                statusMenu.remove()
                isActive = false
            } catch is CancellationError {
                // A newer stop or quit intent owns the final presentation state.
            } catch {
                if isCurrentTransition(generation) {
                    _ = applicationPresence.setMode(.menuBarOnly)
                    mainWindow.hideAfterFailedReturn()
                    desktopHost.reassertDesktopPlacement()
                    transientFailure = .surfaceTimeout
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
                return DesktopStatusState(
                    sourceName: "",
                    isPlaying: false,
                    isTransitioning: false,
                    canPlayNext: false,
                    playbackRate: PlaybackPolicy.defaultRate,
                    videoContentMode: .defaultValue
                )
            }
            return DesktopStatusState(
                sourceName: playback.source?.displayName ?? "",
                isPlaying: playback.isPlaybackRequested,
                isTransitioning: isTransitioning,
                canPlayNext: canPlayNextProvider?() == true,
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
    }

    private func handlePlaybackFailure(_ failure: PlaybackFailure) {
        guard isActive else {
            return
        }
        transientFailure = failure
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

    private func setPlaybackRate(_ rate: PlaybackRate) {
        guard isActive,
              !isTransitioning,
              !isShutDown else {
            return
        }
        playback.setRate(rate)
    }

    private func recoverFromFailedDesktopEntry(
        reportFailure: Bool,
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
        if reportFailure {
            transientFailure = .surfaceTimeout
        }
    }

    private func recoverPlayerWindowFromTransition() {
        transientFailure = nil
        guard applicationPresence.setMode(.standard) else {
            transientFailure = .surfaceTimeout
            return
        }

        invalidateTransition()
        playback.dismissPlayerWindow()
        playback.restorePlayerWindow()
        mainWindow.show()
        desktopHost.close()
        statusMenu.remove()
        isActive = false
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
