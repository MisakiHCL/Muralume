import XCTest
@testable import Muralume

@MainActor
final class DesktopPresetControllerTests: XCTestCase {
    func testLoginRestoreRebuildsQueueBeforeEnteringMutedDesktop() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/DesktopPresetLibrary")
        let first = makeItem(rootURL: rootURL, name: "First", path: "1.mp4")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "2.mp4")
        var queue = PlaybackQueue(
            items: [first.id, second.id],
            startingAt: second.id,
            order: .shuffled
        )
        _ = queue.moveToNext()
        _ = queue.moveToPrevious()
        let queueSnapshot = try XCTUnwrap(queue.makeSnapshot())
        let preset = DesktopPreset(
            queue: queueSnapshot,
            currentTime: 42,
            isPlaybackRequested: true,
            playbackRate: PlaybackRate(rawValue: 1.5),
            videoContentMode: .contain
        )
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [first, second],
            preset: preset
        )
        defer {
            fixture.desktopSession.shutdown()
        }

        let start = fixture.library.start()
        let didRestore = await fixture.controller.restoreAtLogin(after: start)

        XCTAssertTrue(didRestore)
        XCTAssertTrue(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .desktop)
        XCTAssertEqual(fixture.library.currentItemID, second.id)
        XCTAssertEqual(fixture.playback.currentTime, 42)
        XCTAssertEqual(fixture.engine.soughtTimes.last, 42)
        XCTAssertEqual(fixture.playback.settings.rate.rawValue, 1.5)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.isPlaying)
        XCTAssertTrue(fixture.engine.isMuted)
        XCTAssertEqual(
            fixture.desktopHost.preparedContentModes,
            [.contain]
        )
        XCTAssertEqual(fixture.controller.bootstrapState, .active)
    }

    func testLoginRestoreKeepsPausedPresetPaused() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/PausedDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Still", path: "still.mp4")
        let queue = PlaybackQueue(items: [item.id])
        let preset = DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 8,
            isPlaybackRequested: false,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .cover
        )
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: preset
        )
        defer {
            fixture.desktopSession.shutdown()
        }

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertTrue(didRestore)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.engine.isPlaying)
    }

    func testMissingPresetFallsBackWithoutEnteringDesktop() async {
        let rootURL = URL(fileURLWithPath: "/tmp/NoDesktopPreset")
        let fixture = makeFixture(rootURL: rootURL, items: [], preset: nil)
        defer {
            fixture.desktopSession.shutdown()
        }

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertFalse(didRestore)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.controller.bootstrapState, .failed)
    }

    func testFileStoreRoundTripsAndClearsVersionedPreset() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("preset.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let itemID = LibraryMediaItem.ID(
            rootPath: "/tmp/Library",
            relativePath: "clip.mp4"
        )
        let queue = PlaybackQueue(items: [itemID])
        let preset = DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 12,
            isPlaybackRequested: true,
            playbackRate: PlaybackRate(rawValue: 0.5),
            videoContentMode: .cover
        )
        let store = FileDesktopPresetStore(fileURL: fileURL)

        try await store.save(preset)
        let restoredPreset = try await store.load()
        XCTAssertEqual(restoredPreset, preset)

        try await store.clear()
        let clearedPreset = try await store.load()
        XCTAssertNil(clearedPreset)
    }

    func testPreparingAutomaticRestorePersistsCurrentPlayerQueue() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/PreparedDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Prepared", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(item)
        while fixture.playback.readiness != .ready {
            await Task.yield()
        }

        fixture.controller.setAutomaticRestorePrepared(true)
        await fixture.controller.prepareForShutdown()
        let storedPreset = try await store.load()

        XCTAssertEqual(storedPreset?.queue.currentItem, item.id)
        XCTAssertTrue(storedPreset?.isValid == true)
    }

    func testShutdownFinishesClearingPresetAfterRestoreIsDisabled() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/DisabledDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Disabled", path: "clip.mp4")
        let queue = PlaybackQueue(items: [item.id])
        let preset = DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 0,
            isPlaybackRequested: true,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .defaultValue
        )
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }

        fixture.controller.setAutomaticRestorePrepared(true)
        fixture.controller.setAutomaticRestorePrepared(false)
        await fixture.controller.prepareForShutdown()
        let storedPreset = try await store.load()

        XCTAssertNil(storedPreset)
    }

    func testPreparingAutomaticRestoreFailsClosedWhenSaveFails() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/FailedDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Failed", path: "clip.mp4")
        let oldQueue = PlaybackQueue(items: [item.id])
        let oldPreset = DesktopPreset(
            queue: try XCTUnwrap(oldQueue.makeSnapshot()),
            currentTime: 2,
            isPlaybackRequested: false,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .defaultValue
        )
        let store = MemoryDesktopPresetStore(preset: oldPreset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        await store.setFailures(save: true, clear: false)

        let result = await fixture.controller.prepareAutomaticRestore()
        let storedPreset = try await store.load()
        let clearCount = await store.clearCount

        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertEqual(fixture.controller.persistenceFailure, .saveFailed)
        XCTAssertNil(storedPreset)
        XCTAssertEqual(clearCount, 1)
    }

    func testPreparationReportsUnsafeInvalidationFailure() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/UnsafeDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Unsafe", path: "clip.mp4")
        let queue = PlaybackQueue(items: [item.id])
        let oldPreset = DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 4,
            isPlaybackRequested: false,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .defaultValue
        )
        let store = MemoryDesktopPresetStore(preset: oldPreset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        await store.setFailures(save: true, clear: true)

        let result = await fixture.controller.prepareAutomaticRestore()

        XCTAssertEqual(result, .persistenceFailed)
        XCTAssertEqual(
            fixture.controller.persistenceFailure,
            .invalidationFailed
        )
        await store.setFailures(save: false, clear: false)
        let storedPreset = try await store.load()
        XCTAssertEqual(storedPreset, oldPreset)
    }

    func testPreparedRestoreWithoutCurrentQueuePreservesCommittedPresetOnShutdown() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/PreservedDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Preserved", path: "clip.mp4")
        let queue = PlaybackQueue(items: [item.id])
        let preset = DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 6,
            isPlaybackRequested: true,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .defaultValue
        )
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }

        fixture.controller.setAutomaticRestorePrepared(true)
        await fixture.controller.prepareForShutdown()

        let storedPreset = try await store.load()
        XCTAssertEqual(storedPreset, preset)
    }

    func testQueueOrderChangeIsPersistedWhilePlaybackIsPaused() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/QueueRevisionPreset")
        let first = makeItem(rootURL: rootURL, name: "First", path: "1.mp4")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "2.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [first, second],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(first, in: fixture)
        fixture.playback.setPlaybackIntent(.paused)
        fixture.controller.setAutomaticRestorePrepared(true)

        fixture.library.setPlaybackOrder(.ordered)
        await fixture.controller.prepareForShutdown()

        let storedOrder = try await store.load()?.queue.order
        XCTAssertEqual(storedOrder, .ordered)
    }

    func testPlaybackTeardownCannotOverwriteFinalShutdownPreset() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/ShutdownDesktopPreset")
        let item = makeItem(rootURL: rootURL, name: "Playing", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        await prepareActiveQueue(item, in: fixture)
        fixture.controller.setAutomaticRestorePrepared(true)

        await fixture.controller.prepareForShutdown()
        let saveCountAtShutdown = await store.saveCount
        fixture.desktopSession.shutdown()
        await Task.yield()
        await Task.yield()
        let storedPreset = try await store.load()
        let finalSaveCount = await store.saveCount

        XCTAssertTrue(storedPreset?.isPlaybackRequested == true)
        XCTAssertEqual(finalSaveCount, saveCountAtShutdown)
    }

    func testStartupRegistrationRequiresPersistedActiveQueue() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/StartupTransaction")
        let item = makeItem(rootURL: rootURL, name: "Startup", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .enabled
        let launch = LaunchAtLoginController(service: service)
        let startup = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )

        startup.setEnabled(true)
        await waitForStartupUpdate(startup)

        XCTAssertEqual(startup.failure, .selectMediaFirst)
        XCTAssertEqual(service.registerCount, 0)

        await prepareActiveQueue(item, in: fixture)
        startup.setEnabled(true)
        await waitForStartupUpdate(startup)

        XCTAssertEqual(startup.status, .enabled)
        XCTAssertNil(startup.failure)
        XCTAssertEqual(service.registerCount, 1)
        let storedItemID = try await store.load()?.queue.currentItem
        XCTAssertEqual(storedItemID, item.id)
    }

    func testRuntimePresetFailureAutomaticallyDisablesLoginStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RuntimePresetFailure")
        let item = makeItem(rootURL: rootURL, name: "Runtime", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .enabled
        service.statusAfterUnregister = .unavailable(.outsideApplications)
        let launch = LaunchAtLoginController(service: service)
        let startup = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )
        startup.setEnabled(true)
        await waitForStartupUpdate(startup)
        await store.setFailures(save: true, clear: false)

        fixture.playback.setRate(PlaybackRate(rawValue: 1.5))
        while service.unregisterCount == 0 {
            await Task.yield()
        }
        let storedPreset = try await store.load()

        XCTAssertEqual(
            startup.status,
            .unavailable(.outsideApplications)
        )
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
        XCTAssertNil(storedPreset)
    }

    func testFinalShutdownSaveFailureAutomaticallyDisablesStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/FinalSaveFailure")
        let item = makeItem(rootURL: rootURL, name: "Final", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .enabled
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )
        startup.setEnabled(true)
        await waitForStartupUpdate(startup)
        await store.setFailures(save: true, clear: false)

        await startup.prepareForShutdown()
        await fixture.controller.prepareForShutdown()
        startup.freezeAfterPresetFinalization()

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
        XCTAssertEqual(
            fixture.controller.persistenceFailure,
            .saveFailed
        )
        let storedPreset = try await store.load()
        XCTAssertNil(storedPreset)
    }

    func testRegistrationFailureImmediatelyDiscardsPreparedPreset() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/RegistrationFailure")
        let item = makeItem(rootURL: rootURL, name: "Candidate", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        let launch = LaunchAtLoginController(service: service)
        let startup = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )

        startup.setEnabled(true)
        await waitForStartupUpdate(startup)
        let storedPreset = try await store.load()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .enableFailed)
        XCTAssertNil(storedPreset)
    }

    func testShutdownDuringPreparationNeverRegistersLoginItem() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/CancelledRegistration")
        let item = makeItem(rootURL: rootURL, name: "Blocked", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        await store.setBlockSave(true)
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        service.statusAfterRegister = .enabled
        let launch = LaunchAtLoginController(service: service)
        let startup = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )

        startup.setEnabled(true)
        while !(await store.didBeginBlockedSave) {
            await Task.yield()
        }
        let shutdownTask = Task {
            await startup.prepareForShutdown()
        }
        await Task.yield()
        await store.finishBlockedSave()
        await shutdownTask.value
        await fixture.controller.prepareForShutdown()
        let storedPreset = try await store.load()

        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertNil(storedPreset)
    }

    func testDisabledSystemStateClearsStalePreset() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/StalePreset-Disabled")
        let item = makeItem(rootURL: rootURL, name: "Stale", path: "clip.mp4")
        let preset = try makePreset(for: item)
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .disabled)
        let launch = LaunchAtLoginController(service: service)
        _ = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )

        while await store.clearCount == 0 {
            await Task.yield()
        }

        let storedPreset = try await store.load()
        XCTAssertNil(storedPreset)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testUnavailableCopyPreservesSharedRestorePreset() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/StalePreset-Unavailable")
        let item = makeItem(rootURL: rootURL, name: "Stale", path: "clip.mp4")
        let preset = try makePreset(for: item)
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(
            status: .unavailable(.systemService)
        )
        let launch = LaunchAtLoginController(service: service)
        _ = DynamicDesktopStartupController(
            launchAtLogin: launch,
            desktopPreset: fixture.controller
        )

        await fixture.controller.prepareForShutdown()
        let storedPreset = try await store.load()
        let clearCount = await store.clearCount

        XCTAssertEqual(storedPreset, preset)
        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)

        let transitionRootURL = URL(
            fileURLWithPath: "/tmp/StalePreset-UnavailableTransition"
        )
        let transitionItem = makeItem(
            rootURL: transitionRootURL,
            name: "Transition",
            path: "clip.mp4"
        )
        let transitionPreset = try makePreset(for: transitionItem)
        let transitionStore = MemoryDesktopPresetStore(
            preset: transitionPreset
        )
        await transitionStore.setBlockSave(true)
        await transitionStore.setFailures(save: true, clear: false)
        let transitionFixture = makeFixture(
            rootURL: transitionRootURL,
            items: [transitionItem],
            preset: nil,
            store: transitionStore
        )
        defer {
            transitionFixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(transitionItem, in: transitionFixture)
        let transitionService = PresetTestLaunchAtLoginService(
            status: .enabled
        )
        let transitionLaunch = LaunchAtLoginController(
            service: transitionService
        )
        let transitionStartup = DynamicDesktopStartupController(
            launchAtLogin: transitionLaunch,
            desktopPreset: transitionFixture.controller
        )

        while !(await transitionStore.didBeginBlockedSave) {
            await Task.yield()
        }
        transitionService.status = .unavailable(.systemService)
        transitionLaunch.refresh()
        await transitionStore.finishBlockedSave()
        await transitionFixture.controller.prepareForShutdown()
        let transitionStoredPreset = try await transitionStore.load()
        let transitionClearCount = await transitionStore.clearCount

        XCTAssertEqual(
            transitionStartup.status,
            .unavailable(.systemService)
        )
        XCTAssertEqual(transitionStoredPreset, transitionPreset)
        XCTAssertEqual(transitionClearCount, 0)
    }

    func testFailedStalePresetCleanupRetriesOnNextStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/StalePresetRetry")
        let item = makeItem(rootURL: rootURL, name: "Stale", path: "clip.mp4")
        let preset = try makePreset(for: item)
        let store = MemoryDesktopPresetStore(preset: preset)
        await store.setFailures(save: false, clear: true)

        var fixture: DesktopPresetFixture? = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        var startup: DynamicDesktopStartupController? =
            DynamicDesktopStartupController(
                launchAtLogin: LaunchAtLoginController(
                    service: PresetTestLaunchAtLoginService(
                        status: .disabled
                    )
                ),
                desktopPreset: try XCTUnwrap(fixture).controller
            )
        XCTAssertNotNil(startup)
        while await store.clearCount == 0 {
            await Task.yield()
        }
        let unclearedPreset = try await store.load()
        XCTAssertEqual(unclearedPreset, preset)

        fixture?.desktopSession.shutdown()
        startup = nil
        fixture = nil
        await store.setFailures(save: false, clear: false)

        let retryFixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            retryFixture.desktopSession.shutdown()
        }
        _ = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(
                service: PresetTestLaunchAtLoginService(status: .disabled)
            ),
            desktopPreset: retryFixture.controller
        )
        while await store.clearCount < 2 {
            await Task.yield()
        }

        let retriedPreset = try await store.load()
        XCTAssertNil(retriedPreset)
    }

    func testEmptyingRequestedQueueAutomaticallyDisablesStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/EmptyRequestedQueue")
        let item = makeItem(rootURL: rootURL, name: "Active", path: "clip.mp4")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [item],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        fixture.library.removeRoot(try XCTUnwrap(fixture.library.roots.first))
        while service.unregisterCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
        XCTAssertEqual(
            fixture.controller.automaticRestoreInvalidation,
            .noActiveQueue
        )
    }

    func testQueueInvalidationReportsManualRecoveryWhenUnregisterFails() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/FailedQueueUnregister")
        let item = makeItem(rootURL: rootURL, name: "Active", path: "clip.mp4")
        let fixture = makeFixture(rootURL: rootURL, items: [item], preset: nil)
        defer {
            fixture.desktopSession.shutdown()
        }
        await prepareActiveQueue(item, in: fixture)
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.unregisterError = MemoryDesktopPresetStoreError.clearFailed
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        fixture.library.removeRoot(try XCTUnwrap(fixture.library.roots.first))
        while service.unregisterCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(startup.status, .enabled)
        XCTAssertEqual(startup.failure, .manualDisableRequired)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testMissingRequestedPresetAutomaticallyDisablesStartup() async {
        let rootURL = URL(fileURLWithPath: "/tmp/MissingRequestedPreset")
        let store = MemoryDesktopPresetStore(preset: nil)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertFalse(didRestore)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
    }

    func testCorruptRequestedPresetAutomaticallyDisablesStartup() async {
        let rootURL = URL(fileURLWithPath: "/tmp/CorruptRequestedPreset")
        let store = MemoryDesktopPresetStore(preset: nil)
        await store.setInvalidPresetOnLoad(true)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertFalse(didRestore)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
        XCTAssertEqual(
            fixture.controller.automaticRestoreInvalidation,
            .invalidPreset
        )
    }

    func testPermanentRestoreFailureDisablesButTemporaryFailurePreservesRequest() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/PresetAvailability")
        let item = makeItem(rootURL: rootURL, name: "Missing", path: "clip.mp4")
        let preset = try makePreset(for: item)

        let permanentStore = MemoryDesktopPresetStore(preset: preset)
        let permanentFixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: permanentStore
        )
        defer {
            permanentFixture.desktopSession.shutdown()
        }
        let permanentService = PresetTestLaunchAtLoginService(status: .enabled)
        permanentService.statusAfterUnregister = .disabled
        let permanentStartup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(
                service: permanentService
            ),
            desktopPreset: permanentFixture.controller
        )

        let permanentResult = await permanentFixture.controller.restoreAtLogin(
            after: permanentFixture.library.start()
        )

        XCTAssertFalse(permanentResult)
        XCTAssertEqual(permanentService.unregisterCount, 1)
        XCTAssertEqual(permanentStartup.failure, .automaticallyDisabled)

        let temporaryStore = MemoryDesktopPresetStore(preset: preset)
        let temporaryFixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: temporaryStore,
            snapshotRoots: []
        )
        defer {
            temporaryFixture.desktopSession.shutdown()
        }
        let temporaryService = PresetTestLaunchAtLoginService(status: .enabled)
        temporaryService.statusAfterUnregister = .disabled
        let temporaryStartup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(
                service: temporaryService
            ),
            desktopPreset: temporaryFixture.controller
        )

        let temporaryResult = await temporaryFixture.controller.restoreAtLogin(
            after: temporaryFixture.library.start()
        )
        temporaryFixture.playback.setRate(PlaybackRate(rawValue: 1.5))
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(temporaryResult)
        XCTAssertEqual(temporaryService.unregisterCount, 0)
        XCTAssertEqual(temporaryStartup.status, .enabled)
        XCTAssertNil(temporaryStartup.failure)
        let preservedPreset = try await temporaryStore.load()
        XCTAssertEqual(preservedPreset, preset)
    }

    func testNoRestorableRootsAutomaticallyDisablesRequestedStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/NoRestorableRoots")
        let item = makeItem(rootURL: rootURL, name: "Missing", path: "clip.mp4")
        let preset = try makePreset(for: item)
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store,
            restoredRootURLs: []
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertFalse(didRestore)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(startup.status, .disabled)
        XCTAssertEqual(startup.failure, .automaticallyDisabled)
        XCTAssertEqual(
            fixture.controller.automaticRestoreInvalidation,
            .permanentlyUnavailable
        )
        let storedPreset = try await store.load()
        XCTAssertNil(storedPreset)
    }

    func testTemporarilyUnavailableRootsPreserveRequestedStartup() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/UnavailableRestorableRoots")
        let item = makeItem(rootURL: rootURL, name: "Offline", path: "clip.mp4")
        let preset = try makePreset(for: item)
        let store = MemoryDesktopPresetStore(preset: preset)
        let fixture = makeFixture(
            rootURL: rootURL,
            items: [],
            preset: nil,
            store: store,
            restoredRootURLs: [],
            hasUnavailablePersistedFolders: true
        )
        defer {
            fixture.desktopSession.shutdown()
        }
        let service = PresetTestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .disabled
        let startup = DynamicDesktopStartupController(
            launchAtLogin: LaunchAtLoginController(service: service),
            desktopPreset: fixture.controller
        )

        let didRestore = await fixture.controller.restoreAtLogin(
            after: fixture.library.start()
        )

        XCTAssertFalse(didRestore)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertEqual(startup.status, .enabled)
        XCTAssertNil(startup.failure)
        XCTAssertNil(fixture.controller.automaticRestoreInvalidation)
        let storedPreset = try await store.load()
        XCTAssertEqual(storedPreset, preset)
    }

    private func prepareActiveQueue(
        _ item: LibraryMediaItem,
        in fixture: DesktopPresetFixture
    ) async {
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(item)
        while fixture.playback.readiness != .ready {
            await Task.yield()
        }
    }

    private func waitForStartupUpdate(
        _ startup: DynamicDesktopStartupController
    ) async {
        await Task.yield()
        while startup.isUpdating {
            await Task.yield()
        }
        await Task.yield()
    }

    private func makeFixture(
        rootURL: URL,
        items: [LibraryMediaItem],
        preset: DesktopPreset?,
        store suppliedStore: (any DesktopPresetStoring)? = nil,
        snapshotRoots: [MediaLibraryRoot]? = nil,
        restoredRootURLs: [URL]? = nil,
        hasUnavailablePersistedFolders: Bool = false
    ) -> DesktopPresetFixture {
        let engine = TestPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let library = MediaLibraryCoordinator(
            playback: playback,
            folderSelector: EmptyFolderSelector(),
            mediaSession: RestoredMediaSession(
                urls: restoredRootURLs ?? [rootURL],
                hasUnavailablePersistedFolders:
                    hasUnavailablePersistedFolders
            ),
            scanner: PresetMediaScanner(
                snapshot: MediaLibrarySnapshot(
                    roots: snapshotRoots ?? [
                        MediaLibraryRoot(
                            url: rootURL,
                            displayName: rootURL.lastPathComponent
                        )
                    ],
                    items: items
                )
            ),
            playbackOrder: .shuffled
        )
        let desktopHost = TestDesktopHost()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: desktopHost,
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: TestApplicationPresenceController()
        )
        let store = suppliedStore ?? MemoryDesktopPresetStore(preset: preset)
        let controller = DesktopPresetController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: store
        )
        return DesktopPresetFixture(
            controller: controller,
            library: library,
            playback: playback,
            engine: engine,
            desktopSession: desktopSession,
            desktopHost: desktopHost
        )
    }

    private func makePreset(
        for item: LibraryMediaItem
    ) throws -> DesktopPreset {
        let queue = PlaybackQueue(items: [item.id])
        return DesktopPreset(
            queue: try XCTUnwrap(queue.makeSnapshot()),
            currentTime: 0,
            isPlaybackRequested: true,
            playbackRate: PlaybackPolicy.defaultRate,
            videoContentMode: .defaultValue
        )
    }

    private func makeItem(
        rootURL: URL,
        name: String,
        path: String
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: rootURL,
            rootName: rootURL.lastPathComponent,
            url: rootURL.appendingPathComponent(path),
            displayName: name,
            relativePath: path,
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
    }
}

@MainActor
private struct DesktopPresetFixture {
    let controller: DesktopPresetController
    let library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    let engine: TestPlaybackEngine
    let desktopSession: DesktopSessionCoordinator
    let desktopHost: TestDesktopHost
}

@MainActor
private final class EmptyFolderSelector: MediaFolderSelecting {
    func selectFolders() -> [URL] {
        []
    }
}

@MainActor
private final class RestoredMediaSession: MediaAccessSession {
    let urls: [URL]
    let hasUnavailablePersistedFolders: Bool

    init(
        urls: [URL],
        hasUnavailablePersistedFolders: Bool = false
    ) {
        self.urls = urls
        self.hasUnavailablePersistedFolders =
            hasUnavailablePersistedFolders
    }

    func restoreFolders() -> [URL] {
        urls
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        self.urls
    }

    func removeFolder(_ url: URL) -> [URL] {
        urls.filter { $0 != url }
    }

    func stop() {}
}

private final class PresetMediaScanner: MediaLibraryScanning, @unchecked Sendable {
    let snapshot: MediaLibrarySnapshot

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        snapshot
    }
}

private enum MemoryDesktopPresetStoreError: Error {
    case loadFailed
    case saveFailed
    case clearFailed
}

private actor MemoryDesktopPresetStore: DesktopPresetStoring {
    var preset: DesktopPreset?
    private(set) var saveCount = 0
    private(set) var clearCount = 0
    private var shouldFailLoad = false
    private var shouldFailSave = false
    private var shouldFailClear = false
    private var shouldReportInvalidPreset = false
    private var shouldBlockSave = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var didBeginBlockedSave = false

    init(preset: DesktopPreset?) {
        self.preset = preset
    }

    func setFailures(
        load: Bool = false,
        save: Bool,
        clear: Bool
    ) {
        shouldFailLoad = load
        shouldFailSave = save
        shouldFailClear = clear
    }

    func setBlockSave(_ shouldBlock: Bool) {
        shouldBlockSave = shouldBlock
    }

    func setInvalidPresetOnLoad(_ shouldReport: Bool) {
        shouldReportInvalidPreset = shouldReport
    }

    func finishBlockedSave() {
        shouldBlockSave = false
        blockedSaveContinuation?.resume()
        blockedSaveContinuation = nil
    }

    func load() throws -> DesktopPreset? {
        if shouldReportInvalidPreset {
            throw DesktopPresetStoreError.invalidPreset
        }
        if shouldFailLoad {
            throw MemoryDesktopPresetStoreError.loadFailed
        }
        return preset
    }

    func save(_ preset: DesktopPreset) async throws {
        saveCount += 1
        if shouldBlockSave {
            didBeginBlockedSave = true
            await withCheckedContinuation { continuation in
                blockedSaveContinuation = continuation
            }
        }
        if shouldFailSave {
            throw MemoryDesktopPresetStoreError.saveFailed
        }
        self.preset = preset
    }

    func clear() throws {
        clearCount += 1
        if shouldFailClear {
            throw MemoryDesktopPresetStoreError.clearFailed
        }
        preset = nil
    }
}

@MainActor
private final class PresetTestLaunchAtLoginService:
    LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus?
    var statusAfterUnregister: LaunchAtLoginStatus?
    var unregisterError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() {
        registerCount += 1
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
    }

    func openSystemSettings() {}
}
