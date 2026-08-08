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
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playerChrome: PlayerChromeController
    let dynamicDesktopStartup: DynamicDesktopStartupController
    @Published private(set) var isMainWindowFullScreen = false

    private let mainWindowPresenter: MacMainWindowPresenter
    private let applicationPresence: any ApplicationPresenceControlling
    private let desktopPreset: DesktopPresetController
    private let playbackSession: PlaybackSessionController
    private var initialRestoreTask: Task<Void, Never>?
    private var initialRestoreGeneration: UInt64 = 0
    private var hasStarted = false
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
        playbackSession: PlaybackSessionController,
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
        self.playbackSession = playbackSession
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
        desktopSession.playbackOrderProvider = { [weak self] in
            self?.library.playbackOrder
                ?? AppPreferences.defaultValue.playbackOrder
        }
        desktopSession.canSetPlaybackOrderProvider = { [weak self] in
            self?.library.hasActiveQueue == true
        }
        desktopSession.playbackOrderChangeHandler = { [weak self] order in
            self?.library.setPlaybackOrder(order)
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
        mainWindowPresenter.fullScreenStateHandler = { [weak self] state in
            guard let self, isMainWindowFullScreen != state else {
                return
            }
            isMainWindowFullScreen = state
        }
    }

    func start(source: ApplicationLaunchSource) {
        guard !hasStarted, !isShutDown else {
            return
        }
        hasStarted = true
        dynamicDesktopStartup.refresh()
        let libraryStart = library.start()
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
            if restoreResult != .restored
                || plan.presentation == .player {
                showMainWindowInStandardMode()
            }
        }
    }

    func attachMainWindow(_ window: NSWindow) {
        mainWindowPresenter.attach(window)
    }

    func addVideos() {
        guard canImportMedia else {
            return
        }
        performAfterCancellingInitialRestore { [weak self] in
            guard let self, canImportMedia else {
                return
            }
            library.addVideos()
        }
    }

    func addFolders() {
        guard canImportMedia else {
            return
        }
        performAfterCancellingInitialRestore { [weak self] in
            guard let self, canImportMedia else {
                return
            }
            library.addFolders()
        }
    }

    @discardableResult
    func importDroppedURLs(_ urls: [URL]) -> Bool {
        guard canImportMedia, !urls.isEmpty else {
            return false
        }
        let preparation = library.prepareImport(
            urls,
            autoplayFirstExplicitFile: true
        )
        guard let preparation else {
            return true
        }

        commitPreparedDropAfterCancellingInitialRestore(preparation)
        return true
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

    private var canImportMedia: Bool {
        !desktopSession.isActive
            && !desktopSession.isTransitioning
            && !playback.isPlayerWindowDismissed
            && !playerChrome.isSettingsPresented
            && !isShutDown
    }

    func dismissMainWindow() {
        desktopPreset.preserveCurrentPreset()
        playbackSession.preserveCurrentSnapshot()
        playerChrome.setSettingsPresented(false)
        desktopSession.dismissMainWindow()
        mediaThumbnailProvider.purgeMemoryCache()
    }

    func minimizeMainWindow() {
        mainWindowPresenter.minimize()
    }

    func reopenMainWindow() {
        performAfterCancellingInitialRestore { [weak self] in
            self?.revealPlayerWindow()
        }
    }

    private func revealPlayerWindow() {
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

        let pendingInitialRestore = cancelInitialRestore(
            disposition: .shutdown
        )
        await dynamicDesktopStartup.prepareForShutdown()
        await playbackSession.prepareForShutdown()
        await desktopPreset.prepareForShutdown()
        dynamicDesktopStartup.freezeAfterPresetFinalization()
        desktopSession.shutdown()
        await pendingInitialRestore?.value
        await mediaThumbnailProvider.shutdown()
        await library.shutdown()
    }

    func handleApplicationActivation(hasVisibleWindows: Bool) {
        dynamicDesktopStartup.refresh()
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

    private func performAfterCancellingInitialRestore(
        _ action: @escaping @MainActor () -> Void
    ) {
        guard let pendingTask = cancelInitialRestore() else {
            action()
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
        }
    }

    private func commitPreparedDropAfterCancellingInitialRestore(
        _ preparation: MediaLibraryImportPreparation
    ) {
        guard let pendingTask = cancelInitialRestore() else {
            library.commitImport(preparation)
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
                        && canImportMedia
            )
        }
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
                playerChrome.$libraryQueueMode
                    .map { _ in () }
                    .eraseToAnyPublisher()
            ]
        )
        .eraseToAnyPublisher()
    }

    func openSettings() {
        performAfterCancellingInitialRestore { [weak self] in
            self?.openSettingsAfterInitialRestore()
        }
    }

    private func openSettingsAfterInitialRestore() {
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

    func editLibraryFromMenu() {
        guard mainMenuCommandState.canEditLibrary else {
            return
        }
        playerChrome.presentLibraryEditor()
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
        enterDesktop()
    }
}
