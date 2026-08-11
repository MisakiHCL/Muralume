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
            sourceSelector: MacMediaSourcePicker(
                localization: localization
            ),
            mediaSession: UserSelectedMediaSession(
                restoreExecutor: .live
            ),
            scanner: FileSystemMediaLibraryScanner(),
            mediaThumbnailProvider: mediaThumbnailProvider,
            playbackOrder: initialPreferences.playbackOrder,
            playbackRepeatBehavior:
                initialPreferences.playbackRepeatBehavior,
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
        let defaultVideoPlayer = DefaultVideoPlayerController(
            service: MacDefaultVideoPlayerService()
        )

        return AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            mediaThumbnailProvider: mediaThumbnailProvider,
            mainWindowPresenter: mainWindowPresenter,
            applicationPresence: applicationPresence,
            dynamicDesktopStartup: dynamicDesktopStartup,
            defaultVideoPlayer: defaultVideoPlayer,
            desktopPreset: desktopPreset,
            playbackSession: playbackSession
        )
    }
}
