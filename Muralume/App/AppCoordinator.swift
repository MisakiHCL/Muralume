import AppKit
import Combine

@MainActor
final class AppCoordinator: ObservableObject, AppLifecycleCoordinating {
    private enum InitialRestoreCancellationDisposition: Equatable {
        case reopenPlayer
        case shutdown
    }

    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let library: MediaLibraryCoordinator
    let playlists: CustomPlaylistController
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playerChrome: PlayerChromeController
    let dynamicDesktopStartup: DynamicDesktopStartupController
    let defaultVideoPlayer: DefaultVideoPlayerController
    let desktopScene: DesktopSceneController?
    let smartPause: SmartPauseController
    @Published private(set) var isMainWindowFullScreen = false
    @Published private(set) var canRestoreDynamicDesktop = false

    private let mainWindowPresenter: MacMainWindowPresenter
    private let applicationPresence: any ApplicationPresenceControlling
    private let desktopPreset: DesktopPresetController
    private let playbackSession: PlaybackSessionController
    private let externalSubtitlePicker:
        (any ExternalSubtitleSelecting)?
    private let videoScreenshotController:
        (any VideoScreenshotControlling)?
    private let customPlaylistPlaybackBridge:
        CustomPlaylistPlaybackBridge
    private let automaticLibraryRefresh:
        MediaLibraryAutomaticRefreshController
    private let sourceAccessRecoveryMonitor:
        any MediaSourceAccessRecoveryMonitoring
    private var automaticLibraryRefreshCancellables: Set<AnyCancellable> = []
    private var initialRestoreTask: Task<Void, Never>?
    private var sourceAccessRetryTask: Task<Void, Never>?
    private var sourceAccessRetryGeneration: UInt64 = 0
    private var initialRestoreGeneration: UInt64 = 0
    private var hasStarted = false
    private var isShutDown = false
    private var externalOpenGeneration: UInt64 = 0
    private var dynamicDesktopReturnContext: MediaLibraryPlaybackContext?

    init(
        playback: PlaybackCoordinator,
        desktopSession: DesktopSessionCoordinator,
        library: MediaLibraryCoordinator,
        playlists: CustomPlaylistController,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        mainWindowPresenter: MacMainWindowPresenter,
        applicationPresence: any ApplicationPresenceControlling,
        dynamicDesktopStartup: DynamicDesktopStartupController,
        defaultVideoPlayer: DefaultVideoPlayerController,
        desktopPreset: DesktopPresetController,
        playbackSession: PlaybackSessionController,
        mediaLibraryChangeMonitor: any MediaLibraryChangeMonitoring =
            FSEventsMediaLibraryChangeMonitor(),
        automaticLibraryRefreshSchedule:
            MediaLibraryAutomaticRefreshSchedule = .production,
        sourceAccessRecoveryMonitor:
            any MediaSourceAccessRecoveryMonitoring =
                MediaSourceAccessRecoveryMonitor(),
        desktopScene: DesktopSceneController? = nil,
        smartPause: SmartPauseController = SmartPauseController(),
        playerChrome: PlayerChromeController = PlayerChromeController(),
        externalSubtitlePicker:
            (any ExternalSubtitleSelecting)? = nil,
        videoScreenshotController:
            (any VideoScreenshotControlling)? = nil
    ) {
        self.playback = playback
        self.desktopSession = desktopSession
        self.library = library
        self.playlists = playlists
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.mainWindowPresenter = mainWindowPresenter
        self.applicationPresence = applicationPresence
        self.dynamicDesktopStartup = dynamicDesktopStartup
        self.defaultVideoPlayer = defaultVideoPlayer
        self.desktopPreset = desktopPreset
        self.playbackSession = playbackSession
        self.externalSubtitlePicker = externalSubtitlePicker
        self.videoScreenshotController = videoScreenshotController
        customPlaylistPlaybackBridge = CustomPlaylistPlaybackBridge(
            playlists: playlists,
            library: library
        )
        automaticLibraryRefresh = MediaLibraryAutomaticRefreshController(
            monitor: mediaLibraryChangeMonitor,
            target: library,
            debounceNanoseconds:
                automaticLibraryRefreshSchedule.debounceNanoseconds,
            reconciliationNanoseconds:
                automaticLibraryRefreshSchedule.reconciliationNanoseconds
        )
        self.sourceAccessRecoveryMonitor = sourceAccessRecoveryMonitor
        self.desktopScene = desktopScene
        self.smartPause = smartPause
        self.playerChrome = playerChrome

        desktopSession.quitHandler = { [weak self] in
            self?.requestQuit()
        }
        desktopSession.canPlayNextProvider = { [weak self] in
            self?.library.canMoveToNext == true
        }
        desktopSession.playNextHandler = { [weak self] in
            self?.library.playNext()
        }
        desktopSession.playbackOrderProvider = { [weak self] in
            self?.library.playbackOrder
                ?? AppPreferences.defaultValue.playbackOrder
        }
        desktopSession.playbackModeProvider = { [weak self] in
            self?.library.playbackMode
                ?? PlaybackMode(
                    order: AppPreferences.defaultValue.playbackOrder,
                    repeatBehavior:
                        AppPreferences.defaultValue.playbackRepeatBehavior
                )
        }
        desktopSession.canSetPlaybackOrderProvider = { [weak self] in
            self?.library.hasActiveQueue == true
        }
        desktopSession.canSetPlaybackModeProvider = { [weak self] in
            self?.library.hasActiveQueue == true
        }
        desktopSession.playbackOrderChangeHandler = { [weak self] order in
            self?.library.setPlaybackOrder(order)
        }
        desktopSession.playbackModeChangeHandler = { [weak self] mode in
            self?.library.setPlaybackMode(mode)
        }
        desktopSession.didEnterDesktopHandler = { [weak self] in
            self?.desktopPreset.markDesktopActive()
            self?.mediaThumbnailProvider.purgeMemoryCache()
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
        mainWindowPresenter.miniaturizationStateHandler = { [weak playback] state in
            playback?.setSuspended(
                state,
                for: .playerWindowMiniaturized
            )
        }
        mainWindowPresenter.fullScreenStateHandler = { [weak self] state in
            guard let self, isMainWindowFullScreen != state else {
                return
            }
            isMainWindowFullScreen = state
        }
        sourceAccessRecoveryMonitor.recoveryHandler = { [weak self] in
            self?.recoverUnavailableSourceAccessAutomatically()
        }

        library.$monitoredFolderURLs
            .removeDuplicates()
            .sink { [weak automaticLibraryRefresh] folderURLs in
                automaticLibraryRefresh?.update(folderURLs: folderURLs)
            }
            .store(in: &automaticLibraryRefreshCancellables)
        library.$scanState
            .removeDuplicates()
            .sink { [weak automaticLibraryRefresh] scanState in
                automaticLibraryRefresh?.scanStateDidChange(
                    isScanning: scanState == .scanning,
                    lastScanSucceeded: scanState == .ready
                )
            }
            .store(in: &automaticLibraryRefreshCancellables)
    }

    func start(source: ApplicationLaunchSource) {
        guard !hasStarted, !isShutDown else {
            return
        }
        hasStarted = true
        sourceAccessRecoveryMonitor.start()
        automaticLibraryRefresh.start(
            folderURLs: library.monitoredFolderURLs
        )
        dynamicDesktopStartup.refresh()
        initialRestoreGeneration &+= 1
        let generation = initialRestoreGeneration
        initialRestoreTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                playbackSession.finishCancelledRestoreIfNeeded()
                desktopPreset.finishExternalRestore(
                    commitCurrentState: false
                )
                initialRestoreTask = nil
            }

            await customPlaylistPlaybackBridge.startAndWait()
            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }

            let libraryStart = await library.startAsync()
            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }

            if source == .loginItem,
               dynamicDesktopStartup.isEffective {
                playbackSession.beginExternalRestore()
                let didRestore = await desktopPreset.restoreAtLogin(
                    after: libraryStart
                )
                let shouldCommitPlaybackSession =
                    didRestore
                    && generation == initialRestoreGeneration
                    && !isShutDown
                playbackSession.finishExternalRestore(
                    commitCurrentState: shouldCommitPlaybackSession
                )
                guard generation == initialRestoreGeneration,
                      !isShutDown else {
                    return
                }
                if didRestore {
                    restoreLibrarySidebarForActivePlaybackCollection()
                }
                if !didRestore {
                    showMainWindowInStandardMode()
                }
                return
            }

            let presentationOverride: PlaybackSessionPresentation? =
                source == .loginItem ? .player : nil
            let planResult = await playbackSession.makeRestorePlan(
                overridingPresentation: presentationOverride
            )
            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }

            guard case let .restore(plan) = planResult else {
                showMainWindowInStandardMode()
                return
            }

            desktopPreset.beginExternalRestore()
            let restoreResult = await playbackSession.restore(
                plan,
                after: libraryStart
            )
            let shouldCommitDesktopPreset =
                restoreResult == .restored
                && generation == initialRestoreGeneration
                && !isShutDown
            desktopPreset.finishExternalRestore(
                commitCurrentState: shouldCommitDesktopPreset
            )

            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }
            if restoreResult == .restored {
                restoreLibrarySidebarForActivePlaybackCollection()
            }
            if restoreResult != .restored
                || plan.presentation == .player {
                showMainWindowInStandardMode()
            }
        }
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindowPresenter.attach(window)
    }

    func addMedia() {
        guard canImportMedia else {
            return
        }
        performAfterCancellingInitialRestore { [weak self] in
            guard let self, canImportMedia else {
                return
            }
            library.addMedia()
        }
    }

    func loadExternalSubtitle() {
        guard playback.hasPlayableMedia,
              let subtitleURL = externalSubtitlePicker?.selectSubtitle() else {
            return
        }
        playback.loadExternalSubtitle(subtitleURL)
    }

    func reauthorizeMediaSources() {
        guard canImportMedia,
              initialRestoreTask == nil,
              !playbackSession.isRestoring else {
            return
        }
        guard let libraryStart = library.reauthorizeMediaSources() else {
            return
        }
        resumeDeferredPlaybackSession(
            after: libraryStart,
            overridingPresentation: .player
        )
    }

    func reauthorizeMediaSource(_ source: UnavailableMediaSource) {
        guard canImportMedia,
              initialRestoreTask == nil,
              !playbackSession.isRestoring else {
            return
        }
        guard let libraryStart = library.reauthorizeMediaSource(source) else {
            return
        }
        resumeDeferredPlaybackSession(
            after: libraryStart,
            overridingPresentation: .player
        )
    }

    func removeUnavailableMediaSource(_ source: UnavailableMediaSource) {
        guard canImportMedia,
              initialRestoreTask == nil,
              !playbackSession.isRestoring else {
            return
        }
        library.removeUnavailableSource(source)
    }

    func retryUnavailableSourceAccess() {
        startSourceAccessRetry(
            requiresInteractiveAvailability: true,
            resumesDeferredPlayback: true
        )
    }

    private func recoverUnavailableSourceAccessAutomatically() {
        startSourceAccessRetry(
            requiresInteractiveAvailability: false,
            resumesDeferredPlayback: false
        )
    }

    private func startSourceAccessRetry(
        requiresInteractiveAvailability: Bool,
        resumesDeferredPlayback: Bool
    ) {
        guard (!requiresInteractiveAvailability || canImportMedia),
              initialRestoreTask == nil,
              sourceAccessRetryTask == nil,
              !playbackSession.isRestoring,
              !desktopSession.isTransitioning,
              !isShutDown,
              library.canRetrySourceAccess else {
            return
        }
        sourceAccessRetryGeneration &+= 1
        let generation = sourceAccessRetryGeneration
        sourceAccessRetryTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                sourceAccessRetryTask = nil
            }
            let libraryStart = await library
                .retryUnavailableSourceAccessAsync()
            guard !Task.isCancelled,
                  generation == sourceAccessRetryGeneration,
                  !isShutDown else {
                return
            }
            if resumesDeferredPlayback {
                resumeDeferredPlaybackSession(
                    after: libraryStart,
                    overridingPresentation: .player
                )
            }
        }
    }

    @discardableResult
    func importDroppedURLs(_ urls: [URL]) -> Bool {
        guard canImportDroppedMedia, !urls.isEmpty else {
            return false
        }
        let shouldAutoplay = !playerChrome.isSettingsPresented
        let preparation = library.prepareImport(urls)
        guard let preparation else {
            return true
        }

        commitPreparedDropAfterCancellingInitialRestore(
            preparation,
            autoplayExplicitFiles: shouldAutoplay
        )
        return true
    }

    func enterDesktop() {
        guard !playerChrome.isDesktopLayoutPresented else {
            return
        }
        if let desktopScene,
           desktopScene.enabledDisplayCount == 0 {
            presentDesktopLayout()
            return
        }
        cancelSourceAccessRetry()
        if library.isTemporaryPlayback {
            guard library.addTemporaryItemsToLibrary() else {
                return
            }
        }
        library.adoptExternalPlaybackContext()
        clearDynamicDesktopReturnContext()
        playerChrome.setSettingsPresented(false)
        desktopSession.enterDesktop()
    }

    func enterDesktopSynchronized() {
        guard !playerChrome.isDesktopLayoutPresented else {
            return
        }
        if let desktopScene,
           !desktopScene.applySynchronizedToAll(
               contentMode: desktopSession.videoContentMode
           ) {
            presentDesktopLayout()
            return
        }
        enterDesktop()
    }

    func presentDesktopLayout() {
        guard !desktopSession.isActive,
              !desktopSession.isTransitioning,
              playback.canPresentOnDesktop,
              !isShutDown,
              let desktopScene else {
            return
        }
        desktopScene.beginEditing()
        playerChrome.presentDesktopLayout()
    }

    func cancelDesktopLayout() {
        desktopScene?.cancelEditing()
        _ = playerChrome.cancelDesktopLayout()
    }

    func applyDesktopLayout() {
        guard let desktopScene,
              desktopScene.commit() else {
            return
        }
        _ = playerChrome.cancelDesktopLayout()
        enterDesktop()
    }

    func playLibraryItem(_ item: LibraryMediaItem) {
        cancelSourceAccessRetry()
        clearDynamicDesktopReturnContext()
        library.playLibraryItem(item)
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

    private var canImportMedia: Bool {
        canImportDroppedMedia
            && !playerChrome.isSettingsPresented
    }

    private var canImportDroppedMedia: Bool {
        !desktopSession.isActive
            && !desktopSession.isTransitioning
            && sourceAccessRetryTask == nil
            && !playerChrome.isDesktopLayoutPresented
            && !playback.isPlayerWindowDismissed
            && !isShutDown
    }

    func dismissMainWindow() {
        cancelSourceAccessRetry()
        if canRestoreDynamicDesktop {
            restoreDynamicDesktop()
            return
        }
        desktopPreset.preserveCurrentPreset()
        playbackSession.preserveCurrentSnapshot()
        playerChrome.setSettingsPresented(false)
        desktopSession.dismissMainWindow()
        mediaThumbnailProvider.purgeMemoryCache()
    }

    func minimizeMainWindow() {
        cancelSourceAccessRetry()
        mainWindowPresenter.minimize()
    }

    func reopenMainWindow() {
        cancelSourceAccessRetry()
        performAfterCancellingInitialRestore { [weak self] in
            self?.revealPlayerWindow()
        }
    }

    func handleOpenFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isShutDown else {
            return
        }

        cancelSourceAccessRetry()
        externalOpenGeneration &+= 1
        let generation = externalOpenGeneration
        if dynamicDesktopReturnContext == nil,
           isUsingDynamicDesktop,
           let context = library.capturePlaybackContext() {
            dynamicDesktopReturnContext = context
            canRestoreDynamicDesktop = true
            playback.setPlaybackIntent(.paused)
        }
        if dynamicDesktopReturnContext != nil {
            // Freeze persistence and invalidate a concurrent restore before
            // any transition or library scan can suspend this request.
            library.beginExternalPlaybackContext()
        }
        let pendingInitialRestore = cancelInitialRestore()

        Task { [weak self] in
            guard let self else {
                return
            }
            if let pendingInitialRestore {
                await pendingInitialRestore.value
                guard generation == externalOpenGeneration,
                      !isShutDown else {
                    return
                }
                await desktopSession.waitForTransitionToSettle()
                await playbackSession
                    .adoptPlayerPresentationAfterCancelledRestore()
            }

            guard generation == externalOpenGeneration,
                  !isShutDown else {
                return
            }
            playerChrome.setSettingsPresented(false)
            if desktopSession.isActive || desktopSession.isTransitioning {
                desktopSession.returnToPlayer()
                await desktopSession.waitForTransitionToSettle()
            }
            guard generation == externalOpenGeneration,
                  !isShutDown else {
                return
            }
            showMainWindowInStandardMode()

            var libraryItem = singleLibraryItem(forOpenURLs: urls)
            if urls.count == 1,
               libraryItem == nil,
               library.scanState == .scanning {
                _ = await library.waitForStartupScan(after: .alreadyStarted)
                guard generation == externalOpenGeneration,
                      !isShutDown else {
                    return
                }
                libraryItem = singleLibraryItem(forOpenURLs: urls)
            }

            if let libraryItem {
                if dynamicDesktopReturnContext != nil {
                    library.playLibraryItem(
                        libraryItem,
                        preservingExternalContext: true
                    )
                } else {
                    playLibraryItem(libraryItem)
                }
                playerChrome.selectLibrarySidebarSection(.mediaLibrary)
                library.refreshDeferredSourcesIfNeeded()
                return
            }

            let didOpen = await library.openFilesTemporarily(urls)
            guard generation == externalOpenGeneration,
                  !isShutDown else {
                return
            }
            if didOpen {
                playerChrome.selectLibrarySidebarSection(.playQueue)
            } else if dynamicDesktopReturnContext != nil {
                restoreDynamicDesktop()
            }
            library.refreshDeferredSourcesIfNeeded()
        }
    }

    func restoreDynamicDesktop() {
        guard let context = dynamicDesktopReturnContext,
              !isShutDown else {
            return
        }
        cancelSourceAccessRetry()
        externalOpenGeneration &+= 1
        let generation = externalOpenGeneration
        playerChrome.setSettingsPresented(false)
        showMainWindowInStandardMode()

        Task { [weak self] in
            guard let self else {
                return
            }
            let result = await library.restorePlaybackContext(context)
            guard generation == externalOpenGeneration,
                  !isShutDown else {
                return
            }
            guard result == .restored else {
                if result == .permanentlyUnavailable {
                    clearDynamicDesktopReturnContext()
                }
                return
            }
            clearDynamicDesktopReturnContext()
            desktopSession.enterDesktop()
        }
    }

    private func revealPlayerWindow() {
        if desktopSession.isActive || desktopSession.isTransitioning {
            desktopSession.returnToPlayer()
            return
        }

        _ = applicationPresence.setMode(.standard)
        mainWindowPresenter.prepareForReturn()
        mainWindowPresenter.show()
        playback.restorePlayerWindow()
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
        if playerChrome.isDesktopLayoutPresented {
            cancelDesktopLayout()
            return true
        }
        return playerChrome.dismissPresentedPanel()
    }

    func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        sourceAccessRecoveryMonitor.stop()
        sourceAccessRecoveryMonitor.recoveryHandler = nil
        automaticLibraryRefreshCancellables.removeAll()
        automaticLibraryRefresh.stop()
        videoScreenshotController?.cancel()
        externalOpenGeneration &+= 1
        clearDynamicDesktopReturnContext()

        let pendingInitialRestore = cancelInitialRestore(
            disposition: .shutdown
        )
        let pendingSourceAccessRetry = cancelSourceAccessRetry()
        sourceAccessRetryTask = nil
        await dynamicDesktopStartup.prepareForShutdown()
        await playbackSession.prepareForShutdown()
        await desktopPreset.prepareForShutdown()
        dynamicDesktopStartup.freezeAfterPresetFinalization()
        desktopScene?.shutdown()
        desktopSession.shutdown()
        await pendingInitialRestore?.value
        await pendingSourceAccessRetry?.value
        await mediaThumbnailProvider.shutdown()
        await customPlaylistPlaybackBridge.shutdown()
        await library.shutdown()
    }

    func handleApplicationActivation(hasVisibleWindows: Bool) {
        dynamicDesktopStartup.refresh()
        defaultVideoPlayer.refresh()
        recoverUnavailableSourceAccessAutomatically()
        guard !hasVisibleWindows,
              initialRestoreTask == nil,
              !playbackSession.isRestoring,
              !desktopPreset.isBootstrapping,
              !desktopSession.isActive,
              !desktopSession.isTransitioning,
              !isShutDown else {
            return
        }
        reopenMainWindow()
    }

    @discardableResult
    private func cancelInitialRestore(
        disposition: InitialRestoreCancellationDisposition = .reopenPlayer
    ) -> Task<Void, Never>? {
        guard initialRestoreTask != nil
                || playbackSession.isRestoring
                || desktopPreset.isBootstrapping else {
            return nil
        }
        let pendingTask = initialRestoreTask
        initialRestoreGeneration &+= 1
        initialRestoreTask?.cancel()
        if disposition == .reopenPlayer {
            if desktopSession.isTransitioning {
                desktopSession.returnToPlayer(revealWindow: false)
            } else if !desktopSession.isActive {
                library.discardRestoredQueue()
            }
        }
        playbackSession.preserveStoredSnapshotWhileCancellingRestore()
        desktopPreset.markBootstrapCancelled()
        return pendingTask
    }

    @discardableResult
    func cancelSourceAccessRetry() -> Task<Void, Never>? {
        guard let sourceAccessRetryTask else {
            return nil
        }
        sourceAccessRetryGeneration &+= 1
        sourceAccessRetryTask.cancel()
        return sourceAccessRetryTask
    }

    private func performAfterCancellingInitialRestore(
        _ action: @escaping @MainActor () -> Void
    ) {
        guard let pendingTask = cancelInitialRestore() else {
            action()
            library.refreshDeferredSourcesIfNeeded()
            return
        }
        let generation = initialRestoreGeneration
        Task { [weak self] in
            await pendingTask.value
            guard let self,
                  generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }
            await desktopSession.waitForTransitionToSettle()
            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }
            await playbackSession
                .adoptPlayerPresentationAfterCancelledRestore()
            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }
            action()
            library.refreshDeferredSourcesIfNeeded()
        }
    }

    private func commitPreparedDropAfterCancellingInitialRestore(
        _ preparation: MediaLibraryImportPreparation,
        autoplayExplicitFiles: Bool
    ) {
        guard let pendingTask = cancelInitialRestore() else {
            library.commitImport(
                preparation,
                autoplayExplicitFiles: autoplayExplicitFiles
            )
            return
        }
        let restoreGeneration = initialRestoreGeneration
        Task { [weak self] in
            await pendingTask.value
            guard let self, !isShutDown else {
                return
            }
            await desktopSession.waitForTransitionToSettle()
            guard !isShutDown else {
                return
            }

            // Only the action that still owns restore cancellation should
            // adopt presentation state. The import itself is durable and must
            // still be published if a later settings/close action superseded
            // this presentation generation.
            if restoreGeneration == initialRestoreGeneration {
                await playbackSession
                    .adoptPlayerPresentationAfterCancelledRestore()
            }
            guard !isShutDown else {
                return
            }
            library.commitImport(
                preparation,
                autoplayExplicitFiles:
                    restoreGeneration == initialRestoreGeneration
                        && autoplayExplicitFiles
                        && canImportMedia
            )
        }
    }

    private func resumeDeferredPlaybackSession(
        after libraryStart: MediaLibraryStartDisposition,
        overridingPresentation presentationOverride:
            PlaybackSessionPresentation? = nil
    ) {
        guard initialRestoreTask == nil,
              playbackSession.hasDeferredRestorePlan,
              !isShutDown else {
            return
        }

        initialRestoreGeneration &+= 1
        let generation = initialRestoreGeneration
        initialRestoreTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                playbackSession.finishCancelledRestoreIfNeeded()
                desktopPreset.finishExternalRestore(
                    commitCurrentState: false
                )
                initialRestoreTask = nil
            }

            desktopPreset.beginExternalRestore()
            let restoreResult = await playbackSession.resumeDeferredRestore(
                after: libraryStart,
                overridingPresentation: presentationOverride
            )
            let shouldCommitDesktopPreset =
                restoreResult == .restored
                && generation == initialRestoreGeneration
                && !isShutDown
            desktopPreset.finishExternalRestore(
                commitCurrentState: shouldCommitDesktopPreset
            )

            guard generation == initialRestoreGeneration,
                  !isShutDown else {
                return
            }
            if restoreResult == .restored {
                restoreLibrarySidebarForActivePlaybackCollection()
            }
            if restoreResult != .restored
                || playback.presentation == .player {
                showMainWindowInStandardMode()
            }
        }
    }

    private func showMainWindowInStandardMode() {
        guard !isShutDown else {
            return
        }
        _ = applicationPresence.setMode(.standard)
        mainWindowPresenter.prepareForReturn()
        mainWindowPresenter.show()
        playback.restorePlayerWindow()
    }

    private var isUsingDynamicDesktop: Bool {
        if desktopSession.isActive {
            return true
        }
        switch playback.presentation {
        case .desktop:
            return true
        case let .switching(_, destination):
            return destination == .desktop
        case .player, .terminating:
            return false
        }
    }

    private func singleLibraryItem(
        forOpenURLs urls: [URL]
    ) -> LibraryMediaItem? {
        guard urls.count == 1, let url = urls.first else {
            return nil
        }
        return library.libraryItem(matching: url)
    }

    func clearDynamicDesktopReturnContext() {
        dynamicDesktopReturnContext = nil
        canRestoreDynamicDesktop = false
    }
}

extension AppCoordinator: MacMainMenuCommandHandling {
    var mainMenuCommandState: MacMainMenuCommandState {
        let canUseWindowActions =
            !desktopSession.isActive
            && !desktopSession.isTransitioning
            && !playback.isPlayerWindowDismissed
            && !playerChrome.isSettingsPresented
            && !playerChrome.isDesktopLayoutPresented
            && !isShutDown
        let canControlPlayback =
            playback.readiness == .ready
            && playback.presentation == .player
            && canUseWindowActions
        let canEnterDesktop =
            !desktopSession.isActive
            && !desktopSession.isTransitioning
            && !playerChrome.isSettingsPresented
            && !playerChrome.isDesktopLayoutPresented
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
                canControlPlayback && library.canMoveToNext,
            canIncreaseVolume:
                canUseWindowActions
                && playback.settings.volume != .full,
            canDecreaseVolume:
                canUseWindowActions
                && playback.settings.volume != .muted,
            canEnterDesktop: canEnterDesktop,
            canUseWindowActions: canUseWindowActions,
            canEditLibrary:
                canUseWindowActions
                && !library.roots.isEmpty
                && !playerChrome.isLibraryEditing
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
                    .eraseToAnyPublisher(),
                playerChrome.$isDesktopLayoutPresented
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                playerChrome.$libraryQueueMode
                    .map { _ in () }
                    .eraseToAnyPublisher()
            ]
        )
        .eraseToAnyPublisher()
    }

    func openSettings() {
        cancelSourceAccessRetry()
        performAfterCancellingInitialRestore { [weak self] in
            self?.openSettingsAfterInitialRestore()
        }
    }

    private func openSettingsAfterInitialRestore() {
        dynamicDesktopStartup.refresh()
        if playerChrome.isDesktopLayoutPresented {
            cancelDesktopLayout()
        }
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
            mainWindowPresenter.prepareForReturn()
            mainWindowPresenter.show()
            playback.restorePlayerWindow()
            return
        }
        mainWindowPresenter.show()
    }

    func editLibraryFromMenu() {
        guard mainMenuCommandState.canEditLibrary else {
            return
        }
        playerChrome.presentLibraryEditor()
    }

    func togglePlaybackFromMenu() {
        playback.togglePlayback()
    }

    func captureScreenshotFromMenu() {
        guard mainMenuCommandState.canControlPlayback,
              let source = playback.source else {
            return
        }
        videoScreenshotController?.capture(
            source: source,
            at: playback.currentTime
        )
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
        enterDesktop()
    }

    func configureDesktopFromMenu() {
        guard mainMenuCommandState.canEnterDesktop else {
            return
        }
        presentDesktopLayout()
    }
}
