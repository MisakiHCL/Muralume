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
        let applicationPresence = MacApplicationPresenceController()
        let mediaThumbnailProvider = QuickLookMediaThumbnailProvider()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: MacDesktopHost(),
            statusMenu: DesktopStatusMenuController(
                localization: localization
            ),
            videoContentModeStore: UserDefaultsDesktopVideoContentModeStore(),
            lifecycleMonitor: SystemLifecycleMonitor(),
            mainWindow: mainWindowPresenter,
            applicationPresence: applicationPresence
        )
        let library = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: MacMediaFolderPicker(
                localization: localization
            ),
            mediaSession: UserSelectedMediaSession(),
            scanner: FileSystemMediaLibraryScanner(),
            mediaThumbnailProvider: mediaThumbnailProvider,
            playbackOrder: initialPreferences.playbackOrder,
            sort: initialPreferences.librarySort,
            preferencesStore: preferencesStore
        )
        let launchAtLogin = LaunchAtLoginController(
            service: MacLaunchAtLoginService()
        )
        let desktopPreset = DesktopPresetController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: FileDesktopPresetStore()
        )
        let playbackSession = PlaybackSessionController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: FilePlaybackSessionStore()
        )
        let dynamicDesktopStartup = DynamicDesktopStartupController(
            launchAtLogin: launchAtLogin,
            desktopPreset: desktopPreset
        )

        return AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            mediaThumbnailProvider: mediaThumbnailProvider,
            mainWindowPresenter: mainWindowPresenter,
            applicationPresence: applicationPresence,
            dynamicDesktopStartup: dynamicDesktopStartup,
            desktopPreset: desktopPreset,
            playbackSession: playbackSession
        )
    }
}
