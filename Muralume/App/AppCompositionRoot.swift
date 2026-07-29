@MainActor
enum AppCompositionRoot {
    static func makeAppCoordinator(
        localization: AppLocalizationController
    ) -> AppCoordinator {
        let playback = PlaybackCoordinator(
            engine: AVFoundationPlaybackEngine()
        )
        let mainWindowPresenter = MacMainWindowPresenter()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: MacDesktopHost(),
            statusMenu: DesktopStatusMenuController(
                localization: localization
            ),
            videoContentModeStore: UserDefaultsDesktopVideoContentModeStore(),
            lifecycleMonitor: SystemLifecycleMonitor(),
            mainWindow: mainWindowPresenter,
            applicationPresence: MacApplicationPresenceController()
        )
        let library = MediaLibraryCoordinator(
            playback: playback,
            folderSelector: MacMediaFolderPicker(
                localization: localization
            ),
            mediaSession: UserSelectedMediaSession(),
            scanner: FileSystemMediaLibraryScanner()
        )

        return AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            mediaThumbnailProvider: QuickLookMediaThumbnailProvider(),
            mainWindowPresenter: mainWindowPresenter
        )
    }
}
