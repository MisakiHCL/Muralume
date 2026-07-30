import AppKit
import Combine

@MainActor
final class AppCoordinator: ObservableObject, AppLifecycleCoordinating {
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let library: MediaLibraryCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playerChrome: PlayerChromeController
    @Published private(set) var isMainWindowFullScreen = false

    private let mainWindowPresenter: MacMainWindowPresenter
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        desktopSession: DesktopSessionCoordinator,
        library: MediaLibraryCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        mainWindowPresenter: MacMainWindowPresenter,
        playerChrome: PlayerChromeController = PlayerChromeController()
    ) {
        self.playback = playback
        self.desktopSession = desktopSession
        self.library = library
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mainWindowPresenter = mainWindowPresenter
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

    func start() {
        library.start()
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
        playerChrome.setSettingsPresented(false)
        desktopSession.dismissMainWindow()
    }

    func minimizeMainWindow() {
        mainWindowPresenter.minimize()
    }

    func reopenMainWindow() {
        if desktopSession.isActive || desktopSession.isTransitioning {
            desktopSession.returnToPlayer()
            return
        }

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

        desktopSession.shutdown()
        await mediaThumbnailProvider.shutdown()
        await library.shutdown()
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
}
