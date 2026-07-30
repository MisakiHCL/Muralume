@MainActor
enum AppCompositionRoot {
    static func makeAppCoordinator(
        localization: AppLocalizationController,
        initialPreferences: AppPreferences,
        preferencesStore: any AppPreferencesStoring
    ) -> AppCoordinator {
        let playback = PlaybackCoordinator(
            engine: AVFoundationPlaybackEngine(),
            initialPreferences: initialPreferences,
            preferencesStore: preferencesStore
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
            scanner: FileSystemMediaLibraryScanner(),
            playbackOrder: initialPreferences.playbackOrder,
            sort: initialPreferences.librarySort,
            preferencesStore: preferencesStore
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
