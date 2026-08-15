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
        let videoContentModeStore =
            UserDefaultsDesktopVideoContentModeStore()
        let desktopScene = DesktopSceneController(
            store: UserDefaultsDesktopSceneStore(),
            topology: MacDesktopDisplayTopology(),
            legacyContentMode: videoContentModeStore.load()
        )
        let independentDesktopPlayback = DesktopPlaybackOrchestrator {
            AVFoundationPlaybackEngine()
        }
        let smartPause = SmartPauseController(
            preferences: initialPreferences.smartPause,
            store: preferencesStore
        )
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: MacDesktopHost(),
            statusMenu: DesktopStatusMenuController(
                localization: localization
            ),
            videoContentModeStore: videoContentModeStore,
            lifecycleMonitor: SystemLifecycleMonitor(),
            mainWindow: mainWindowPresenter,
            applicationPresence: applicationPresence,
            sceneController: desktopScene,
            independentPlayback: independentDesktopPlayback,
            smartPausePreferences: smartPause.preferences
        )
        smartPause.preferencesDidChangeHandler = {
            [weak desktopSession] preferences in
            desktopSession?.updateSmartPausePreferences(preferences)
        }
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
        let playlists = CustomPlaylistController(
            store: FileCustomPlaylistStore()
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
        desktopSession.independentSourceResolver = { [weak library] itemID in
            guard let item = library?.mediaItem(forPersistedID: itemID) else {
                return nil
            }
            return ResolvedMediaSource(
                url: item.url,
                displayName: item.displayName
            )
        }
        library.mediaItemsWillBeRemovedHandler = {
            [weak desktopSession] itemIDs in
            await desktopSession?.drainMediaItems(itemIDs)
        }
        library.prepareForMediaScopeShutdownHandler = {
            [weak desktopSession] in
            await desktopSession?.prepareForMediaScopeShutdown()
        }

        return AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            playlists: playlists,
            mediaThumbnailProvider: mediaThumbnailProvider,
            mainWindowPresenter: mainWindowPresenter,
            applicationPresence: applicationPresence,
            dynamicDesktopStartup: dynamicDesktopStartup,
            defaultVideoPlayer: defaultVideoPlayer,
            desktopPreset: desktopPreset,
            playbackSession: playbackSession,
            desktopScene: desktopScene,
            smartPause: smartPause
        )
    }
}
