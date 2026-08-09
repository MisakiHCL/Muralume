import AppKit
import XCTest
@testable import Muralume

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private enum TestPolicy {
        static let propagationAttempts = 1_000
    }

    func testInteractiveLaunchUsesPlaybackSessionInsteadOfLoginPreset() async {
        let fixture = makeFixture(launchStatus: .enabled)

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
        }
        let loadCount = await fixture.store.loadCount
        let sessionLoadCount = await fixture.sessionStore.loadCount

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(sessionLoadCount, 1)
        XCTAssertEqual(fixture.applicationPresence.appliedModes, [.standard])

        await fixture.coordinator.shutdown()
    }

    func testRepeatedStartLoadsPlaybackSessionOnlyOnce() async {
        let fixture = makeFixture(launchStatus: .disabled)

        fixture.coordinator.start(source: .interactive)
        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
        }
        let sessionLoadCount = await fixture.sessionStore.loadCount

        XCTAssertEqual(sessionLoadCount, 1)

        await fixture.coordinator.shutdown()
    }

    func testDockReopenCancelsBlockedPlaybackSessionRestore() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            blockSessionLoad: true,
            sessionPresentation: .desktop
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            await fixture.sessionStore.didBeginBlockedLoad
        }

        fixture.coordinator.reopenMainWindow()
        XCTAssertFalse(fixture.window.isVisible)

        await fixture.sessionStore.finishBlockedLoad()
        await waitUntil {
            fixture.window.isVisible
                && !fixture.playbackSession.isRestoring
        }

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(
            fixture.applicationPresence.appliedModes,
            [.standard]
        )

        await fixture.coordinator.shutdown()
    }

    func testSettingsSupersedesPreparedVideoDropAutoplayButStillRefreshes()
        async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            blockSessionLoad: true
        )
        let droppedVideoURL = URL(
            fileURLWithPath: "/tmp/AppCoordinatorTests/Dropped Video.mov"
        )
        let droppedVideo = LibraryMediaItem(
            rootURL: droppedVideoURL,
            rootName: droppedVideoURL.lastPathComponent,
            kind: .file,
            url: droppedVideoURL,
            displayName: "Dropped Video",
            relativePath: "",
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
        fixture.scanner.replaceSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fixture.item.rootURL,
                        displayName: fixture.item.rootName
                    ),
                    MediaLibraryRoot(
                        url: droppedVideoURL,
                        displayName: droppedVideoURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [fixture.item, droppedVideo]
            )
        )
        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            await fixture.sessionStore.didBeginBlockedLoad
        }

        XCTAssertTrue(
            fixture.coordinator.importDroppedURLs([droppedVideoURL])
        )
        fixture.coordinator.openSettings()
        await fixture.sessionStore.finishBlockedLoad()
        await waitUntil {
            fixture.coordinator.playerChrome.isSettingsPresented
                && fixture.scanner.scannedRootURLs.contains {
                    $0.contains(droppedVideoURL)
                }
        }

        XCTAssertTrue(
            fixture.mediaSession.activeSources.contains {
                $0.url == droppedVideoURL
            }
        )
        XCTAssertTrue(fixture.engine.loadedSources.isEmpty)
        XCTAssertNil(fixture.playback.source)

        await fixture.coordinator.shutdown()
    }

    func testLatestOfTwoDropsDuringBlockedRestoreAutoplaysOnce() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            blockSessionLoad: true
        )
        let firstURL = URL(
            fileURLWithPath: "/tmp/AppCoordinatorTests/First Drop.mov"
        )
        let latestURL = URL(
            fileURLWithPath: "/tmp/AppCoordinatorTests/Latest Drop.mov"
        )
        let makeDroppedItem: (URL, String) -> LibraryMediaItem = {
            url,
            displayName in
            LibraryMediaItem(
                rootURL: url,
                rootName: url.lastPathComponent,
                kind: .file,
                url: url,
                displayName: displayName,
                relativePath: "",
                relativeDirectory: "",
                creationDate: nil,
                fileSize: 1
            )
        }
        let first = makeDroppedItem(firstURL, "First Drop")
        let latest = makeDroppedItem(latestURL, "Latest Drop")
        fixture.scanner.replaceSnapshot(
            MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: fixture.item.rootURL,
                        displayName: fixture.item.rootName
                    ),
                    MediaLibraryRoot(
                        url: firstURL,
                        displayName: firstURL.lastPathComponent,
                        kind: .file
                    ),
                    MediaLibraryRoot(
                        url: latestURL,
                        displayName: latestURL.lastPathComponent,
                        kind: .file
                    )
                ],
                items: [fixture.item, first, latest]
            )
        )
        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            await fixture.sessionStore.didBeginBlockedLoad
        }

        XCTAssertTrue(fixture.coordinator.importDroppedURLs([firstURL]))
        XCTAssertTrue(fixture.coordinator.importDroppedURLs([latestURL]))
        await fixture.sessionStore.finishBlockedLoad()
        await waitUntil {
            fixture.library.scanState == .ready
                && fixture.library.currentItemID == latest.id
                && fixture.engine.loadedSources.count == 1
        }

        XCTAssertTrue(
            fixture.mediaSession.activeSources.contains {
                $0.url == firstURL
            }
        )
        XCTAssertTrue(
            fixture.mediaSession.activeSources.contains {
                $0.url == latestURL
            }
        )
        XCTAssertTrue(
            fixture.scanner.scannedRootURLs.contains {
                Set($0.map { $0.standardizedFileURL.path })
                    == Set([
                        firstURL.standardizedFileURL.path,
                        latestURL.standardizedFileURL.path
                    ])
            }
        )
        XCTAssertEqual(fixture.library.currentItemID, latest.id)
        XCTAssertEqual(fixture.playback.source?.url, latestURL)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [latestURL])

        await fixture.coordinator.shutdown()
    }

    func testLoginLaunchFallsBackToPlayerWhenApprovalIsNotEffective() async {
        let fixture = makeFixture(launchStatus: .requiresApproval)

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.window.isVisible
        }
        let loadCount = await fixture.store.loadCount
        let sessionLoadCount = await fixture.sessionStore.loadCount

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(sessionLoadCount, 1)
        XCTAssertEqual(fixture.applicationPresence.appliedModes, [.standard])

        await fixture.coordinator.shutdown()
    }

    func testEffectiveLoginLaunchStartsRestoreWithoutShowingPlayer() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockPresetLoad: true
        )

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            await fixture.store.didBeginBlockedLoad
        }

        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertTrue(fixture.applicationPresence.appliedModes.isEmpty)

        await fixture.store.finishBlockedLoad()
        await fixture.coordinator.shutdown()
    }

    func testDockReopenCancelsInFlightBootstrapWithoutLateHide() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockDesktopAttachment: true
        )

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.engine.didBeginBlockedDesktopAttachment
        }

        fixture.engine.blockPlayerAttachment()
        fixture.coordinator.reopenMainWindow()
        await waitUntil {
            fixture.engine.didBeginBlockedPlayerAttachment
        }
        XCTAssertFalse(fixture.window.isVisible)

        fixture.engine.finishBlockedDesktopAttachment()
        await waitUntil {
            fixture.desktopPreset.bootstrapState == .cancelled
        }
        XCTAssertFalse(fixture.window.isVisible)

        fixture.engine.finishBlockedPlayerAttachment()
        await waitUntil {
            fixture.window.isVisible
                && fixture.playback.presentation == .player
                && !fixture.desktopSession.isTransitioning
        }
        await Task.yield()

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(fixture.applicationPresence.appliedModes.last, .standard)

        await fixture.coordinator.shutdown()
        let playbackSnapshot = await fixture.sessionStore.value()
        XCTAssertEqual(playbackSnapshot?.presentation, .player)
    }

    func testShutdownCancelsAndDrainsBootstrapBeforeFinalTeardown() async {
        let fixture = makeFixture(
            launchStatus: .enabled,
            blockDesktopAttachment: true
        )
        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.engine.didBeginBlockedDesktopAttachment
        }

        let shutdownTask = Task {
            await fixture.coordinator.shutdown()
        }
        await waitUntil {
            fixture.engine.stopCount == 1
        }

        XCTAssertEqual(fixture.thumbnailProvider.shutdownCount, 0)
        XCTAssertEqual(fixture.mediaSession.stopCount, 0)

        fixture.engine.finishBlockedDesktopAttachment()
        await shutdownTask.value

        XCTAssertEqual(fixture.thumbnailProvider.shutdownCount, 1)
        XCTAssertEqual(fixture.mediaSession.stopCount, 1)
        let persistenceCounts = await fixture.store.persistenceCounts

        fixture.engine.emitProgress(99)
        await Task.yield()
        await Task.yield()
        let finalPersistenceCounts = await fixture.store.persistenceCounts

        XCTAssertEqual(finalPersistenceCounts, persistenceCounts)
    }

    func testDockReopenResumesSoftClosedPlaybackAndPersistsIntent() async {
        let fixture = makeFixture(launchStatus: .disabled)
        fixture.coordinator.start(source: .interactive)
        await prepareActiveQueue(in: fixture)

        fixture.coordinator.dismissMainWindow()

        XCTAssertTrue(fixture.playback.isPlayerWindowDismissed)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(
            fixture.thumbnailProvider.purgeMemoryCacheCount,
            1
        )

        fixture.coordinator.reopenMainWindow()
        await waitUntil {
            fixture.window.isVisible && fixture.engine.isPlaying
        }

        XCTAssertFalse(fixture.playback.isPlayerWindowDismissed)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        fixture.coordinator.dismissMainWindow()
        XCTAssertEqual(
            fixture.thumbnailProvider.purgeMemoryCacheCount,
            2
        )
        await fixture.coordinator.shutdown()

        let snapshot = await fixture.sessionStore.value()
        XCTAssertEqual(snapshot?.presentation, .player)
        XCTAssertEqual(snapshot?.state.isPlaybackRequested, true)
    }

    func testMenuLibraryEditOpensPlaylistEditorAndRevalidatesSources() async {
        let fixture = makeFixture(launchStatus: .disabled)

        fixture.coordinator.playerChrome.setPlaylistPresented(false)
        fixture.coordinator.editLibraryFromMenu()

        XCTAssertFalse(fixture.coordinator.playerChrome.isPlaylistPresented)
        XCTAssertFalse(fixture.coordinator.playerChrome.isLibraryEditing)
        XCTAssertFalse(
            fixture.coordinator.mainMenuCommandState.canEditLibrary
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            !fixture.library.roots.isEmpty && fixture.window.isVisible
        }

        XCTAssertTrue(fixture.coordinator.mainMenuCommandState.canEditLibrary)

        fixture.coordinator.editLibraryFromMenu()

        XCTAssertTrue(fixture.coordinator.playerChrome.isPlaylistPresented)
        XCTAssertTrue(fixture.coordinator.playerChrome.isLibraryEditing)
        XCTAssertFalse(
            fixture.coordinator.mainMenuCommandState.canEditLibrary
        )

        await fixture.coordinator.shutdown()
    }

    func testDesktopStatusPlaybackOrderUsesLibraryQueueTruth() async {
        let fixture = makeFixture(launchStatus: .disabled)
        fixture.coordinator.start(source: .interactive)
        await prepareActiveQueue(in: fixture)

        fixture.statusMenu.setPlaybackOrderHandler?(.shuffled)
        XCTAssertEqual(fixture.library.playbackOrder, .ordered)

        fixture.coordinator.enterDesktop()
        await waitUntil {
            fixture.desktopSession.isActive
                && fixture.playback.presentation == .desktop
        }

        XCTAssertEqual(
            fixture.statusMenu.stateProvider?().playbackOrder,
            .ordered
        )
        XCTAssertTrue(
            fixture.statusMenu.stateProvider?().canSetPlaybackOrder == true
        )

        fixture.statusMenu.setPlaybackOrderHandler?(.shuffled)

        XCTAssertEqual(fixture.library.playbackOrder, .shuffled)
        XCTAssertEqual(fixture.library.makeQueueSnapshot()?.order, .shuffled)
        XCTAssertEqual(
            fixture.statusMenu.stateProvider?().playbackOrder,
            .shuffled
        )

        await fixture.coordinator.shutdown()
    }

    func testMenuDesktopActionRestoresSoftClosedPlayerBeforeTransition() async {
        let fixture = makeFixture(launchStatus: .disabled)
        fixture.coordinator.start(source: .interactive)
        await prepareActiveQueue(in: fixture)

        fixture.coordinator.dismissMainWindow()

        XCTAssertTrue(fixture.playback.isPlayerWindowDismissed)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertTrue(fixture.coordinator.mainMenuCommandState.canEnterDesktop)

        fixture.coordinator.enterDesktopFromMenu()
        await waitUntil {
            fixture.desktopSession.isActive
                && fixture.playback.presentation == .desktop
        }

        XCTAssertFalse(fixture.playback.isPlayerWindowDismissed)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.isPlaying)
        XCTAssertTrue(fixture.engine.isMuted)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(fixture.desktopHost.revealCount, 1)
        XCTAssertEqual(fixture.applicationPresence.appliedModes.last, .menuBarOnly)
        XCTAssertEqual(
            fixture.thumbnailProvider.purgeMemoryCacheCount,
            2
        )

        await fixture.coordinator.shutdown()
    }

    func testInteractiveLaunchRestoresLastDesktopWithoutShowingPlayer() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            sessionPresentation: .desktop
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.desktopSession.isActive
                && fixture.playback.presentation == .desktop
                && fixture.playback.isPlaybackRequested
        }

        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(fixture.library.currentItemID, fixture.item.id)
        XCTAssertEqual(fixture.playback.currentTime, 12)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(
            fixture.applicationPresence.appliedModes,
            [.menuBarOnly]
        )

        await fixture.coordinator.shutdown()
    }

    func testNonEffectiveLoginLaunchForcesSavedDesktopIntoPlayer() async {
        let fixture = makeFixture(
            launchStatus: .requiresApproval,
            sessionPresentation: .desktop
        )

        fixture.coordinator.start(source: .loginItem)
        await waitUntil {
            fixture.window.isVisible
                && fixture.playback.readiness == .ready
        }

        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(fixture.library.currentItemID, fixture.item.id)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(
            fixture.applicationPresence.appliedModes,
            [.standard]
        )

        await fixture.coordinator.shutdown()
    }

    func testRetryRestoresDeferredDesktopSessionIntoVisiblePlayer() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            sessionPresentation: .desktop,
            sourceInitiallyAvailable: false
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
                && !fixture.playbackSession.isRestoring
        }

        XCTAssertEqual(
            fixture.library.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertTrue(fixture.playbackSession.hasDeferredRestorePlan)
        XCTAssertTrue(fixture.engine.loadedSources.isEmpty)

        fixture.mediaSession.makePersistedSourceAvailable()
        fixture.coordinator.retryUnavailableSourceAccess()
        await waitUntil {
            fixture.playback.readiness == .ready
                && !fixture.playbackSession.isRestoring
        }

        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.library.currentItemID, fixture.item.id)
        XCTAssertEqual(
            fixture.library.makeQueueSnapshot()?.currentItem,
            fixture.item.id
        )
        XCTAssertEqual(fixture.playback.currentTime, 12)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertFalse(fixture.playbackSession.hasDeferredRestorePlan)
        let sessionLoadCount = await fixture.sessionStore.loadCount
        XCTAssertEqual(sessionLoadCount, 1)

        fixture.coordinator.retryUnavailableSourceAccess()
        await Task.yield()
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)

        await fixture.coordinator.shutdown()
    }

    func testReauthorizationCancelPreservesDeferredSession() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            sessionPresentation: .desktop,
            sourceInitiallyAvailable: false,
            selectedSources: [[]]
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
                && !fixture.playbackSession.isRestoring
        }
        let scansBeforeCancel = fixture.scanner.scannedRootURLs

        fixture.coordinator.reauthorizeMediaSources()

        XCTAssertEqual(
            fixture.sourceSelector.intents,
            [.reauthorizingSources]
        )
        XCTAssertEqual(
            fixture.library.sourceAccessState,
            .temporarilyUnavailable
        )
        XCTAssertTrue(fixture.playbackSession.hasDeferredRestorePlan)
        XCTAssertTrue(fixture.mediaSession.activeSources.isEmpty)
        XCTAssertEqual(fixture.scanner.scannedRootURLs, scansBeforeCancel)
        XCTAssertTrue(fixture.engine.loadedSources.isEmpty)

        await fixture.coordinator.shutdown()
    }

    func testReauthorizationRestoresDeferredSessionIntoVisiblePlayer()
        async
    {
        let fixture = makeFixture(
            launchStatus: .disabled,
            sessionPresentation: .desktop,
            sourceInitiallyAvailable: false,
            selectedSources: nil
        )
        fixture.sourceSelector.replaceSelections([[fixture.item.rootURL]])

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
                && !fixture.playbackSession.isRestoring
        }

        fixture.coordinator.reauthorizeMediaSources()
        await waitUntil {
            fixture.playback.readiness == .ready
                && !fixture.playbackSession.isRestoring
        }

        XCTAssertEqual(
            fixture.sourceSelector.intents,
            [.reauthorizingSources]
        )
        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(fixture.library.currentItemID, fixture.item.id)
        XCTAssertEqual(fixture.playback.currentTime, 12)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertFalse(fixture.playbackSession.hasDeferredRestorePlan)

        await fixture.coordinator.shutdown()
    }

    func testUserActionCancellingDeferredRetryClearsRestorePlan() async {
        let fixture = makeFixture(
            launchStatus: .disabled,
            sessionPresentation: .desktop,
            sourceInitiallyAvailable: false
        )

        fixture.coordinator.start(source: .interactive)
        await waitUntil {
            fixture.window.isVisible
                && !fixture.playbackSession.isRestoring
        }
        fixture.mediaSession.makePersistedSourceAvailable()
        fixture.engine.blockPlayerAttachment()

        fixture.coordinator.retryUnavailableSourceAccess()
        await waitUntil {
            fixture.engine.didBeginBlockedPlayerAttachment
        }

        fixture.coordinator.openSettings()
        fixture.engine.finishBlockedPlayerAttachment()
        await waitUntil {
            fixture.coordinator.playerChrome.isSettingsPresented
                && !fixture.playbackSession.isRestoring
        }

        XCTAssertFalse(fixture.playbackSession.hasDeferredRestorePlan)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertFalse(fixture.desktopSession.isActive)

        await fixture.coordinator.shutdown()
    }

    private func prepareActiveQueue(in fixture: AppCoordinatorFixture) async {
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(fixture.item)
        await waitUntil {
            fixture.playback.readiness == .ready
        }
    }

    private func makeFixture(
        launchStatus: LaunchAtLoginStatus,
        blockPresetLoad: Bool = false,
        blockDesktopAttachment: Bool = false,
        blockSessionLoad: Bool = false,
        sessionPresentation: PlaybackSessionPresentation? = nil,
        sourceInitiallyAvailable: Bool = true,
        selectedSources: [[URL]]? = nil
    ) -> AppCoordinatorFixture {
        let rootURL = URL(
            fileURLWithPath: "/tmp/AppCoordinatorTests/Library"
        )
        let item = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent("clip.mp4"),
            displayName: "Clip",
            relativePath: "clip.mp4",
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
        let queue = PlaybackQueue(items: [item.id])
        let preset = DesktopPreset(
            queue: queue.makeSnapshot()!,
            currentTime: 12,
            isPlaybackRequested: true,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .cover
        )
        let engine = AppCoordinatorPlaybackEngine(
            blocksDesktopAttachment: blockDesktopAttachment
        )
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        let mediaSession = AppCoordinatorMediaSession(
            rootURL: rootURL,
            initiallyAvailable: sourceInitiallyAvailable
        )
        let sourceSelector = AppCoordinatorSourceSelector(
            selections: selectedSources ?? []
        )
        let thumbnailProvider = AppCoordinatorThumbnailProvider()
        let scanner = AppCoordinatorMediaScanner(
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [item]
            )
        )
        let library = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: sourceSelector,
            mediaSession: mediaSession,
            scanner: scanner,
            mediaThumbnailProvider: thumbnailProvider,
            playbackOrder: .ordered
        )
        let windowPresenter = MacMainWindowPresenter()
        let applicationPresence = TestApplicationPresenceController()
        let desktopHost = TestDesktopHost()
        let statusMenu = TestDesktopStatusPresenter()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: statusMenu,
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: windowPresenter,
            applicationPresence: applicationPresence
        )
        let store = AppCoordinatorPresetStore(
            preset: preset,
            blocksLoad: blockPresetLoad
        )
        let desktopPreset = DesktopPresetController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: store
        )
        let sessionStore = AppCoordinatorPlaybackSessionStore(
            snapshot: sessionPresentation.map {
                PlaybackSessionSnapshot(
                    state: preset,
                    presentation: $0
                )
            },
            blocksLoad: blockSessionLoad
        )
        let playbackSession = PlaybackSessionController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: sessionStore
        )
        let launchService = AppCoordinatorLaunchAtLoginService(
            status: launchStatus
        )
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: launchService),
            desktopPreset: desktopPreset
        )
        let coordinator = AppCoordinator(
            playback: playback,
            desktopSession: desktopSession,
            library: library,
            mediaThumbnailProvider: thumbnailProvider,
            mainWindowPresenter: windowPresenter,
            applicationPresence: applicationPresence,
            dynamicDesktopStartup: startup,
            desktopPreset: desktopPreset,
            playbackSession: playbackSession
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        coordinator.attachMainWindow(window)

        return AppCoordinatorFixture(
            coordinator: coordinator,
            playback: playback,
            desktopSession: desktopSession,
            statusMenu: statusMenu,
            desktopPreset: desktopPreset,
            playbackSession: playbackSession,
            library: library,
            desktopHost: desktopHost,
            applicationPresence: applicationPresence,
            thumbnailProvider: thumbnailProvider,
            sourceSelector: sourceSelector,
            mediaSession: mediaSession,
            scanner: scanner,
            store: store,
            sessionStore: sessionStore,
            engine: engine,
            playerSurface: playerSurface,
            item: item,
            window: window
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<TestPolicy.propagationAttempts {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for coordinator state propagation")
    }
}

@MainActor
private struct AppCoordinatorFixture {
    let coordinator: AppCoordinator
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let statusMenu: TestDesktopStatusPresenter
    let desktopPreset: DesktopPresetController
    let playbackSession: PlaybackSessionController
    let library: MediaLibraryCoordinator
    let desktopHost: TestDesktopHost
    let applicationPresence: TestApplicationPresenceController
    let thumbnailProvider: AppCoordinatorThumbnailProvider
    let sourceSelector: AppCoordinatorSourceSelector
    let mediaSession: AppCoordinatorMediaSession
    let scanner: AppCoordinatorMediaScanner
    let store: AppCoordinatorPresetStore
    let sessionStore: AppCoordinatorPlaybackSessionStore
    let engine: AppCoordinatorPlaybackEngine
    let playerSurface: TestPlaybackSurface
    let item: LibraryMediaItem
    let window: NSWindow
}

@MainActor
private final class AppCoordinatorPlaybackEngine: PlaybackEngine {
    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?

    private(set) var didBeginBlockedDesktopAttachment = false
    private(set) var didBeginBlockedPlayerAttachment = false
    private(set) var isPlaying = false
    private(set) var isMuted = false
    private(set) var stopCount = 0
    private(set) var loadedSources: [ResolvedMediaSource] = []
    private var blocksDesktopAttachment: Bool
    private var desktopAttachmentContinuation:
        CheckedContinuation<Void, any Error>?
    private var shouldBlockPlayerAttachment = false
    private var playerAttachmentContinuation:
        CheckedContinuation<Void, Never>?

    init(blocksDesktopAttachment: Bool) {
        self.blocksDesktopAttachment = blocksDesktopAttachment
    }

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        loadedSources.append(source)
        return 120
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        if surface.id == .desktop, blocksDesktopAttachment {
            didBeginBlockedDesktopAttachment = true
            try await withCheckedThrowingContinuation { continuation in
                desktopAttachmentContinuation = continuation
            }
        } else if surface.id == .player, shouldBlockPlayerAttachment {
            didBeginBlockedPlayerAttachment = true
            await withCheckedContinuation { continuation in
                playerAttachmentContinuation = continuation
            }
        }
    }

    func blockPlayerAttachment() {
        shouldBlockPlayerAttachment = true
    }

    func finishBlockedDesktopAttachment() {
        blocksDesktopAttachment = false
        desktopAttachmentContinuation?.resume()
        desktopAttachmentContinuation = nil
    }

    func finishBlockedPlayerAttachment() {
        shouldBlockPlayerAttachment = false
        playerAttachmentContinuation?.resume()
        playerAttachmentContinuation = nil
    }

    func detachAll() {}

    func play(at rate: PlaybackRate) {
        isPlaying = true
        playbackActivityHandler?(true)
    }

    func pause() {
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {}

    func setVolume(_ volume: PlaybackVolume) {}

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    func stop() {
        stopCount += 1
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func emitProgress(_ seconds: TimeInterval) {
        progressHandler?(seconds)
    }
}

@MainActor
private final class AppCoordinatorSourceSelector: MediaSourceSelecting {
    private var selections: [[URL]]
    private(set) var intents: [MediaSourceSelectionIntent] = []

    init(selections: [[URL]]) {
        self.selections = selections
    }

    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL] {
        intents.append(intent)
        guard !selections.isEmpty else {
            return []
        }
        return selections.removeFirst()
    }

    func replaceSelections(_ selections: [[URL]]) {
        self.selections = selections
    }
}

@MainActor
private final class AppCoordinatorMediaSession: MediaAccessSession {
    private(set) var activeSources: [MediaSource]
    private(set) var stopCount = 0
    private let persistedSource: MediaSource
    private var persistedSourceIsAvailable: Bool

    var hasUnavailablePersistedSources: Bool {
        !persistedSourceIsAvailable
    }

    init(rootURL: URL, initiallyAvailable: Bool) {
        persistedSource = MediaSource(url: rootURL, kind: .folder)
        persistedSourceIsAvailable = initiallyAvailable
        activeSources = initiallyAvailable ? [persistedSource] : []
    }

    func restoreSources() -> [MediaSource] {
        activeSources
    }

    func retryUnavailableSources() -> [MediaSource] {
        if persistedSourceIsAvailable,
           !activeSources.contains(where: { $0.id == persistedSource.id }) {
            activeSources.append(persistedSource)
        }
        return activeSources
    }

    func makePersistedSourceAvailable() {
        persistedSourceIsAvailable = true
    }

    func addSources(_ urls: [URL]) -> MediaAccessUpdate {
        var didChangeSources = false
        for url in urls {
            let source = MediaSource(
                url: url,
                kind: MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                    url.pathExtension.lowercased()
                ) ? .file : .folder
            )
            if !activeSources.contains(where: { $0.id == source.id }) {
                activeSources.append(source)
                didChangeSources = true
            }
            if source.id == persistedSource.id {
                persistedSourceIsAvailable = true
            }
        }
        return MediaAccessUpdate(
            activeSources: activeSources,
            requestedFileURLs: urls.filter {
                MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                    $0.pathExtension.lowercased()
                )
            },
            acceptedRequestCount: urls.count,
            rejectedRequestCount: 0,
            didChangeSources: didChangeSources
        )
    }

    func removeSource(_ source: MediaSource) -> [MediaSource] {
        activeSources.removeAll { $0.id == source.id }
        return activeSources
    }

    func stop() {
        stopCount += 1
    }
}

private final class AppCoordinatorMediaScanner:
    MediaLibraryScanning,
    @unchecked Sendable {
    private var snapshot: MediaLibrarySnapshot
    private let lock = NSLock()
    private var storedScannedRootURLs: [[URL]] = []

    var scannedRootURLs: [[URL]] {
        lock.withLock { storedScannedRootURLs }
    }

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        lock.withLock {
            storedScannedRootURLs.append(rootURLs)
            return snapshot
        }
    }

    func replaceSnapshot(_ snapshot: MediaLibrarySnapshot) {
        lock.withLock {
            self.snapshot = snapshot
        }
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        .available
    }
}

private actor AppCoordinatorPresetStore: DesktopPresetStoring {
    private var preset: DesktopPreset?
    private var blocksLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var clearCount = 0
    private(set) var didBeginBlockedLoad = false

    var persistenceCounts: [Int] {
        [saveCount, clearCount]
    }

    init(preset: DesktopPreset?, blocksLoad: Bool) {
        self.preset = preset
        self.blocksLoad = blocksLoad
    }

    func load() async throws -> DesktopPreset? {
        loadCount += 1
        if blocksLoad {
            didBeginBlockedLoad = true
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return preset
    }

    func finishBlockedLoad() {
        blocksLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func save(_ preset: DesktopPreset) async throws {
        saveCount += 1
        self.preset = preset
    }

    func clear() async throws {
        clearCount += 1
        preset = nil
    }
}

private actor AppCoordinatorPlaybackSessionStore: PlaybackSessionStoring {
    private var snapshot: PlaybackSessionSnapshot?
    private var blocksLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var clearCount = 0
    private(set) var didBeginBlockedLoad = false

    init(
        snapshot: PlaybackSessionSnapshot?,
        blocksLoad: Bool = false
    ) {
        self.snapshot = snapshot
        self.blocksLoad = blocksLoad
    }

    func load() async throws -> PlaybackSessionSnapshot? {
        loadCount += 1
        if blocksLoad {
            didBeginBlockedLoad = true
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return snapshot
    }

    func finishBlockedLoad() {
        blocksLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func value() -> PlaybackSessionSnapshot? {
        snapshot
    }

    func save(_ snapshot: PlaybackSessionSnapshot) async throws {
        saveCount += 1
        self.snapshot = snapshot
    }

    func clear() async throws {
        clearCount += 1
        snapshot = nil
    }
}

@MainActor
private final class AppCoordinatorLaunchAtLoginService:
    LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() {
        status = .enabled
    }

    func unregister() {
        status = .disabled
    }

    func openSystemSettings() {}
}

@MainActor
private final class AppCoordinatorThumbnailProvider: MediaThumbnailProviding {
    private(set) var purgeMemoryCacheCount = 0
    private(set) var shutdownCount = 0

    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        nil
    }

    func purgeMemoryCache() {
        purgeMemoryCacheCount += 1
    }

    func allowThumbnails(forRootIDs rootIDs: Set<MediaLibraryRoot.ID>) {}

    func invalidateThumbnails(
        forRootID rootID: MediaLibraryRoot.ID
    ) async {}

    func shutdown() async {
        shutdownCount += 1
    }
}
