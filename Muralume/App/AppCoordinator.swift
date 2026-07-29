import AppKit
import Combine

@MainActor
final class AppCoordinator: ObservableObject, AppLifecycleCoordinating {
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let library: MediaLibraryCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    @Published private(set) var isMainWindowFullScreen = false

    private let mainWindowPresenter: MacMainWindowPresenter
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        desktopSession: DesktopSessionCoordinator,
        library: MediaLibraryCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        mainWindowPresenter: MacMainWindowPresenter
    ) {
        self.playback = playback
        self.desktopSession = desktopSession
        self.library = library
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mainWindowPresenter = mainWindowPresenter

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
