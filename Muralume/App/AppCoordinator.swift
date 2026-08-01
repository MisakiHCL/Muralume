import AppKit
import Combine

@MainActor
final class AppCoordinator: ObservableObject, AppLifecycleCoordinating {
    private enum LoginBootstrapCancellationDisposition: Equatable {
        case reopenPlayer
        case shutdown
    }

    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let library: MediaLibraryCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playerChrome: PlayerChromeController
    let dynamicDesktopStartup: DynamicDesktopStartupController
    @Published private(set) var isMainWindowFullScreen = false

    private let mainWindowPresenter: MacMainWindowPresenter
    private let applicationPresence: any ApplicationPresenceControlling
    private let desktopPreset: DesktopPresetController
    private var loginBootstrapTask: Task<Void, Never>?
    private var loginBootstrapGeneration: UInt64 = 0
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        desktopSession: DesktopSessionCoordinator,
        library: MediaLibraryCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        mainWindowPresenter: MacMainWindowPresenter,
        applicationPresence: any ApplicationPresenceControlling,
        dynamicDesktopStartup: DynamicDesktopStartupController,
        desktopPreset: DesktopPresetController,
        playerChrome: PlayerChromeController = PlayerChromeController()
    ) {
        self.playback = playback
        self.desktopSession = desktopSession
        self.library = library
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mainWindowPresenter = mainWindowPresenter
        self.applicationPresence = applicationPresence
        self.dynamicDesktopStartup = dynamicDesktopStartup
        self.desktopPreset = desktopPreset
        self.playerChrome = playerChrome

        desktopSession.quitHandler = { [weak self] in
            self?.requestQuit()
        }
        desktopSession.canPlayNextProvider = { [weak self] in
            self?.library.hasActiveQueue == true
        }
        desktopSession.playNextHandler = { [weak self] in
            self?.library.playNext()
        }
        desktopSession.didEnterDesktopHandler = { [weak desktopPreset] in
            desktopPreset?.markDesktopActive()
        }
        desktopSession.didReturnToPlayerHandler = { [weak desktopPreset] in
            desktopPreset?.markDesktopInactive()
        }
        desktopSession.didStopPlaybackHandler = { [weak desktopPreset] in
            desktopPreset?.markDesktopInactive()
        }
        mainWindowPresenter.unexpectedWindowCloseHandler = { [weak self] in
            self?.dismissMainWindow()
        }
        mainWindowPresenter.fullScreenStateHandler = { [weak self] state in
            guard let self, isMainWindowFullScreen != state else {
                return
            }
            isMainWindowFullScreen = state
        }
    }

    func start(source: ApplicationLaunchSource) {
        dynamicDesktopStartup.refresh()
        let libraryStart = library.start()

        guard source == .loginItem,
              dynamicDesktopStartup.isEffective else {
            showMainWindowInStandardMode()
            return
        }

        loginBootstrapGeneration &+= 1
        let generation = loginBootstrapGeneration
        loginBootstrapTask = Task { [weak self] in
            guard let self else {
                return
            }
            let didRestore = await desktopPreset.restoreAtLogin(
                after: libraryStart
            )
            guard generation == loginBootstrapGeneration,
                  !isShutDown else {
                return
            }
            loginBootstrapTask = nil
            if !didRestore {
                showMainWindowInStandardMode()
            }
        }
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindowPresenter.attach(window)
    }

    func addFolders() {
        guard !desktopSession.isActive,
              !desktopSession.isTransitioning,
              !isShutDown else {
            return
        }
        library.addFolders()
    }

    func enterDesktop() {
        playerChrome.setSettingsPresented(false)
        desktopSession.enterDesktop()
    }

    func returnToPlayer() {
        desktopSession.returnToPlayer()
    }

    func toggleFullScreen() {
        guard !desktopSession.isActive else {
            return
        }
        mainWindowPresenter.toggleFullScreen()
    }

    func dismissMainWindow() {
        desktopPreset.preserveCurrentPreset()
        playerChrome.setSettingsPresented(false)
        desktopSession.dismissMainWindow()
    }

    func minimizeMainWindow() {
        mainWindowPresenter.minimize()
    }

    func reopenMainWindow() {
        cancelLoginBootstrap()
        if desktopSession.isActive || desktopSession.isTransitioning {
            desktopSession.returnToPlayer()
            return
        }

        _ = applicationPresence.setMode(.standard)
        playback.restorePlayerWindow()
        mainWindowPresenter.show()
    }

    func handleCloseCommand(for window: NSWindow?) -> Bool {
        guard mainWindowPresenter.isPresenting(window) else {
            return false
        }
        dismissMainWindow()
        return true
    }

    func requestQuit() {
        NSApp.terminate(nil)
    }

    func toggleSettings() {
        if playerChrome.isSettingsPresented {
            playerChrome.setSettingsPresented(false)
        } else {
            openSettings()
        }
    }

    @discardableResult
    func dismissPresentedPanel() -> Bool {
        playerChrome.dismissPresentedPanel()
    }

    func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true

        let pendingLoginBootstrap = cancelLoginBootstrap(
            disposition: .shutdown
        )
        await dynamicDesktopStartup.prepareForShutdown()
        await desktopPreset.prepareForShutdown()
        dynamicDesktopStartup.freezeAfterPresetFinalization()
        desktopSession.shutdown()
        await pendingLoginBootstrap?.value
        await mediaThumbnailProvider.shutdown()
        await library.shutdown()
    }

    func handleApplicationActivation(hasVisibleWindows: Bool) {
        dynamicDesktopStartup.refresh()
        guard !hasVisibleWindows,
              loginBootstrapTask == nil,
              !desktopPreset.isBootstrapping,
              !desktopSession.isActive,
              !desktopSession.isTransitioning,
              !isShutDown else {
            return
        }
        reopenMainWindow()
    }

    @discardableResult
    private func cancelLoginBootstrap(
        disposition: LoginBootstrapCancellationDisposition = .reopenPlayer
    ) -> Task<Void, Never>? {
        guard loginBootstrapTask != nil || desktopPreset.isBootstrapping else {
            return nil
        }
        let pendingTask = loginBootstrapTask
        loginBootstrapGeneration &+= 1
        loginBootstrapTask?.cancel()
        loginBootstrapTask = nil
        if disposition == .reopenPlayer {
            if desktopSession.isTransitioning {
                desktopSession.returnToPlayer()
            } else if !desktopSession.isActive {
                library.discardRestoredQueue()
            }
        }
        desktopPreset.markBootstrapCancelled()
        return pendingTask
    }

    private func showMainWindowInStandardMode() {
        guard !isShutDown else {
            return
        }
        _ = applicationPresence.setMode(.standard)
        playback.restorePlayerWindow()
        mainWindowPresenter.show()
    }
}

extension AppCoordinator: MacMainMenuCommandHandling {
    var mainMenuCommandState: MacMainMenuCommandState {
        let canUseWindowActions =
            !desktopSession.isActive
            && !desktopSession.isTransitioning
            && !playback.isPlayerWindowDismissed
            && !playerChrome.isSettingsPresented
            && !isShutDown
        let canControlPlayback =
            playback.readiness == .ready
            && playback.presentation == .player
            && canUseWindowActions
        let canEnterDesktop =
            !desktopSession.isActive
            && !desktopSession.isTransitioning
            && !playerChrome.isSettingsPresented
            && !isShutDown
            && playback.readiness == .ready
            && playback.presentation == .player

        return MacMainMenuCommandState(
            isPlaybackRequested: playback.isPlaybackRequested,
            isMuted: playback.settings.isMuted,
            canControlPlayback: canControlPlayback,
            canPlayPrevious:
                canControlPlayback && library.canMoveToPrevious,
            canPlayNext:
                canControlPlayback && library.hasActiveQueue,
            canIncreaseVolume:
                canUseWindowActions
                && playback.settings.volume != .full,
            canDecreaseVolume:
                canUseWindowActions
                && playback.settings.volume != .muted,
            canEnterDesktop: canEnterDesktop,
            canUseWindowActions: canUseWindowActions
        )
    }

    var mainMenuCommandStateDidChange: AnyPublisher<Void, Never> {
        let playbackCommandChanges: [AnyPublisher<Void, Never>] = [
            playback.$readiness
                .map { _ in () }
                .eraseToAnyPublisher(),
            playback.$presentation
                .map { _ in () }
                .eraseToAnyPublisher(),
            playback.$isPlaybackRequested
                .map { _ in () }
                .eraseToAnyPublisher(),
            playback.$settings
                .map { _ in () }
                .eraseToAnyPublisher(),
            playback.$isPlayerWindowDismissed
                .map { _ in () }
                .eraseToAnyPublisher()
        ]

        return Publishers.MergeMany(
            playbackCommandChanges + [
                desktopSession.objectWillChange.eraseToAnyPublisher(),
                library.objectWillChange.eraseToAnyPublisher(),
                playerChrome.$presentedPanel
                    .map { _ in () }
                    .eraseToAnyPublisher()
            ]
        )
        .eraseToAnyPublisher()
    }

    func openSettings() {
        cancelLoginBootstrap()
        dynamicDesktopStartup.refresh()
        if playerChrome.isSettingsPresented {
            guard !desktopSession.isActive,
                  !desktopSession.isTransitioning else {
                return
            }
            mainWindowPresenter.show()
            return
        }

        playerChrome.setSettingsPresented(true)
        if desktopSession.isActive || desktopSession.isTransitioning {
            desktopSession.returnToPlayer()
            return
        }
        if playback.isPlayerWindowDismissed {
            playback.restorePlayerWindow()
        }
        mainWindowPresenter.show()
    }

    func togglePlaybackFromMenu() {
        playback.togglePlayback()
    }

    func seekBackwardFromMenu() {
        playback.skip(by: -PlaybackPolicy.seekStepSeconds)
    }

    func seekForwardFromMenu() {
        playback.skip(by: PlaybackPolicy.seekStepSeconds)
    }

    func playPreviousFromMenu() {
        library.playPrevious()
    }

    func playNextFromMenu() {
        library.playNext()
    }

    func increaseVolumeFromMenu() {
        playback.adjustVolume(by: PlaybackPolicy.volumeStep)
    }

    func decreaseVolumeFromMenu() {
        playback.adjustVolume(by: -PlaybackPolicy.volumeStep)
    }

    func toggleMuteFromMenu() {
        playback.setMuted(!playback.settings.isMuted)
    }

    func enterDesktopFromMenu() {
        guard mainMenuCommandState.canEnterDesktop else {
            return
        }
        if playback.isPlayerWindowDismissed {
            playback.restorePlayerWindow()
        }
        enterDesktop()
    }
}
