import Foundation

@MainActor
enum AppCompositionRoot {
    static func makeAppCoordinator(
        localization: AppLocalizationController,
        initialPreferences: AppPreferences,
        preferencesStore: any AppPreferencesStoring
    ) -> AppCoordinator {
        let playlistStoreFileURL: URL?
        do {
            playlistStoreFileURL = try DebugUITestSession.playlistStoreFileURL()
        } catch {
            preconditionFailure(
                "The UI-test app requires a valid MURALUME_UI_TEST_SESSION_ID UUID."
            )
        }
        let playback = PlaybackCoordinator(
            engine: AVFoundationPlaybackEngine(),
            initialPreferences: initialPreferences,
            preferencesStore: preferencesStore,
            externalSubtitleParser: SubtitleFileParser(),
            externalSubtitleDiscovery: SubtitleSidecarDiscovery(),
            externalSubtitleAssociationStore:
                UserDefaultsExternalSubtitleAssociationStore()
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
        let playbackProgressStore = FilePlaybackProgressStore()
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
        let mediaSession = UserSelectedMediaSession(
            restoreExecutor: .live,
            importExecutor: .live
        )
        let library = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: MacMediaSourcePicker(
                localization: localization
            ),
            mediaSession: mediaSession,
            scanner: FileSystemMediaLibraryScanner(),
            mediaThumbnailProvider: mediaThumbnailProvider,
            playbackOrder: initialPreferences.playbackOrder,
            playbackRepeatBehavior:
                initialPreferences.playbackRepeatBehavior,
            sort: initialPreferences.librarySort,
            preferencesStore: preferencesStore,
            playbackProgressStore: playbackProgressStore
        )
        let playlists = CustomPlaylistController(
            store: FileCustomPlaylistStore(fileURL: playlistStoreFileURL),
            grantCapture: { [weak mediaSession] item in
                mediaSession?.persistentAccessGrant(
                    for: MediaSource.ID(standardizedPath: item.id.rootPath)
                )
            },
            sourceGrantCapture: { [weak mediaSession] sourceID in
                mediaSession?.persistentAccessGrant(for: sourceID)
            },
            resolver: SecurityScopedCustomPlaylistMediaAccess()
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
                displayName: item.displayName,
                accessLease: item.accessLease
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
            smartPause: smartPause,
            playerChrome: PlayerChromeController(
                librarySidebarController: LibrarySidebarController(
                    mediaBrowserLayout: initialPreferences.libraryBrowserLayout,
                    preferencesStore: preferencesStore
                )
            ),
            externalSubtitlePicker: MacExternalSubtitlePicker(
                localization: localization
            ),
            videoScreenshotController: MacVideoScreenshotController(
                localization: localization
            )
        )
    }
}

/// Only the separately identified Debug test app can redirect playlist storage.
/// Resolve its temporary directory in the app process, never in the UI runner.
enum DebugUITestSession {
    enum ConfigurationError: Error, Equatable {
        case missingSessionIdentifier
        case invalidSessionIdentifier
    }

    static let appBundleIdentifier = "com.muralume.Muralume.uitesting"
    static let environmentKey = "MURALUME_UI_TEST_SESSION_ID"
    static let directoryName = "MuralumeUITests"
    static let playlistFileName = "custom-playlists.json"

    static func playlistStoreFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL? {
#if DEBUG
        guard bundleIdentifier == appBundleIdentifier else { return nil }
        guard let value = environment[environmentKey] else {
            throw ConfigurationError.missingSessionIdentifier
        }
        guard let sessionID = UUID(uuidString: value),
              sessionID.uuidString.caseInsensitiveCompare(value) == .orderedSame else {
            throw ConfigurationError.invalidSessionIdentifier
        }
        return temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(playlistFileName, isDirectory: false)
#else
        return nil
#endif
    }
}
