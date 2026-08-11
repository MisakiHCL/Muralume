import XCTest
@testable import Muralume

@MainActor
final class PlaybackSessionControllerTests: XCTestCase {
    func testFileStoreRoundTripsAndClearsSnapshot() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 42,
            isPlaying: true,
            presentation: .desktop,
            videoContentMode: .blurredBackground
        )
        let store = FilePlaybackSessionStore(fileURL: fileURL)

        try await store.save(snapshot)
        let externalReplacement = Data("external replacement".utf8)
        try externalReplacement.write(to: fileURL, options: [.atomic])
        try await store.save(snapshot)
        let restoredSnapshot = try await store.load()
        XCTAssertEqual(restoredSnapshot, snapshot)

        try await store.clear()
        let clearedSnapshot = try await store.load()
        XCTAssertNil(clearedSnapshot)
    }

    func testFileStoreRejectsOversizedSnapshotWithoutChangingFile()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let oversizedData = Data(repeating: 0x41, count: 65)
        try oversizedData.write(to: fileURL)
        let store = FilePlaybackSessionStore(
            fileURL: fileURL,
            maximumFileByteCount: 64
        )

        do {
            _ = try await store.load()
            XCTFail("Expected the oversized session to be rejected.")
        } catch let error as PlaybackSessionStoreError {
            XCTAssertEqual(
                error,
                .fileTooLarge(maximumByteCount: 64, observedByteCount: 65)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), oversizedData)
    }

    func testFileStoreRejectsOversizedSaveWithoutReplacingLastKnownGood()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let lastKnownGood = Data("last-known-good".utf8)
        try lastKnownGood.write(to: fileURL)
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 0,
            isPlaying: false,
            presentation: .player
        )
        let store = FilePlaybackSessionStore(
            fileURL: fileURL,
            maximumFileByteCount: 64
        )

        do {
            try await store.save(snapshot)
            XCTFail("Expected the oversized encoded session to be rejected.")
        } catch let error as PlaybackSessionStoreError {
            guard case let .fileTooLarge(maximum, observed) = error else {
                return XCTFail("Expected fileTooLarge, received \(error).")
            }
            XCTAssertEqual(maximum, 64)
            XCTAssertGreaterThan(observed, maximum)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), lastKnownGood)
    }

    func testFileStoreRejectsCorruptSnapshotWithoutChangingFile()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let corruptData = Data("{".utf8)
        try corruptData.write(to: fileURL)
        let store = FilePlaybackSessionStore(
            fileURL: fileURL,
            maximumFileByteCount: 64
        )

        do {
            _ = try await store.load()
            XCTFail("Expected the corrupt session to be rejected.")
        } catch is DecodingError {
            // Expected: the store leaves recovery data untouched for diagnosis.
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
    }

    func testFileStoreReportsQueueLimitWithoutChangingSnapshot()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let itemCount = PlaybackQueuePolicy.maximumPersistedItemCount + 1
        let itemIDs = (0..<itemCount).map {
            LibraryMediaItem.ID(
                rootPath: "/tmp/Library",
                relativePath: "\($0).mp4"
            )
        }
        let queue = PlaybackQueueSnapshot(
            items: itemIDs,
            order: .ordered,
            currentItem: itemIDs[0],
            roundNumber: 1,
            currentRoundPosition: 1,
            remainingItems: [],
            remainingIndex: 0,
            history: [],
            forwardHistory: []
        )
        let snapshot = PlaybackSessionSnapshot(
            state: DesktopPreset(
                queue: queue,
                currentTime: 0,
                isPlaybackRequested: false,
                playbackRate: PlaybackPolicy.defaultRate,
                videoContentMode: .defaultValue
            ),
            presentation: .player
        )
        let persistedData = try JSONEncoder().encode(snapshot)
        try persistedData.write(to: fileURL)
        let store = FilePlaybackSessionStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected the oversized queue to be rejected.")
        } catch let error as PlaybackSessionStoreError {
            XCTAssertEqual(
                error,
                .queueLimitExceeded(
                    itemCount: itemCount,
                    historyEntryCount: 0
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), persistedData)
    }

    func testTypedStoreContentErrorsInvalidateStoredSnapshot() async {
        let errors: [PlaybackSessionStoreError] = [
            .invalidSnapshot,
            .fileTooLarge(maximumByteCount: 64, observedByteCount: 65),
            .queueLimitExceeded(itemCount: 50_001, historyEntryCount: 0)
        ]

        for error in errors {
            let store = MemoryPlaybackSessionStore(snapshot: nil)
            await store.setLoadError(error)
            let fixture = makeFixture(items: [], store: store)

            let result = await fixture.controller.makeRestorePlan()
            let storedSnapshot = await store.value()
            let clearCount = await store.clearCount

            XCTAssertEqual(result, .invalidSnapshot)
            XCTAssertNil(storedSnapshot)
            XCTAssertEqual(clearCount, 1)

            fixture.desktopSession.shutdown()
            await fixture.library.shutdown()
        }
    }

    func testFileStoreDecodesVersionOneContainSessionFromV102() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let versionOneJSON = #"""
        {
          "schemaVersion": 1,
          "state": {
            "schemaVersion": 1,
            "queue": {
              "items": [
                { "rootPath": "/tmp/Library", "relativePath": "clip.mp4" }
              ],
              "order": "ordered",
              "currentItem": {
                "rootPath": "/tmp/Library",
                "relativePath": "clip.mp4"
              },
              "roundNumber": 1,
              "currentRoundPosition": 1,
              "remainingItems": [
                { "rootPath": "/tmp/Library", "relativePath": "clip.mp4" }
              ],
              "remainingIndex": 1,
              "history": [],
              "forwardHistory": []
            },
            "currentTime": 24,
            "isPlaybackRequested": false,
            "playbackRateValue": 1,
            "videoContentMode": "contain"
          },
          "presentation": "desktop"
        }
        """#
        try Data(versionOneJSON.utf8).write(to: fileURL)

        let restoredSnapshot = try await FilePlaybackSessionStore(
            fileURL: fileURL
        ).load()

        XCTAssertEqual(restoredSnapshot?.schemaVersion, 1)
        XCTAssertEqual(restoredSnapshot?.state.videoContentMode, .contain)
        XCTAssertEqual(restoredSnapshot?.presentation, .desktop)
        XCTAssertTrue(restoredSnapshot?.isValid == true)
    }

    func testPlayerRestoreResumesCurrentItemTimeAndPlayback() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 42,
            isPlaying: true,
            presentation: .player
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.library.currentItemID, items[1].id)
        XCTAssertEqual(fixture.playback.currentTime, 42)
        XCTAssertEqual(fixture.engine.soughtTimes.last, 42)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertFalse(
            fixture.applicationPresence.appliedModes.contains(.menuBarOnly)
        )

        await shutdown(fixture)
    }

    func testPausedPlayerRestoreNeverRequestsTransientPlayback() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 18,
            isPlaying: false,
            presentation: .player
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.engine.playCallCount, 0)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)

        await shutdown(fixture)
    }

    func testCancelledRestoreAdoptsPlayerAndDeferredPlayingIntent()
        async throws
    {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 18,
            isPlaying: true,
            presentation: .desktop
        )
        let store = MemoryPlaybackSessionStore(snapshot: snapshot)
        let fixture = makeFixture(items: items, store: store)

        let planResult = await fixture.controller.makeRestorePlan()
        guard case .restore = planResult else {
            XCTFail("Expected a restorable playback session.")
            return
        }
        let libraryStart = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: libraryStart)
        let queueResult = await fixture.library.restoreQueue(
            from: snapshot.state.queue,
            attachToPlayerSurface: true
        )
        fixture.controller.finishCancelledRestoreIfNeeded()

        XCTAssertEqual(queueResult, .restored)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)

        await fixture.controller
            .adoptPlayerPresentationAfterCancelledRestore()
        let storedSnapshot = await store.value()

        XCTAssertEqual(storedSnapshot?.presentation, .player)
        XCTAssertTrue(
            storedSnapshot?.state.isPlaybackRequested == true
        )
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        await shutdown(fixture)
    }

    func testDesktopRestoreEntersActiveMenuBarOnlyPresentation() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 24,
            isPlaying: true,
            presentation: .desktop
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertTrue(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .desktop)
        XCTAssertEqual(
            fixture.applicationPresence.appliedModes.last,
            .menuBarOnly
        )
        XCTAssertEqual(fixture.engine.attachedSurfaceIDs.last, .desktop)

        await shutdown(fixture)
    }

    func testNormalShutdownPersistsActiveDesktopPresentation() async throws {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)

        let didEnterDesktop = await fixture.desktopSession.enterDesktopAndWait()
        await fixture.controller.prepareForShutdown()
        let storedSnapshot = await store.value()

        XCTAssertTrue(didEnterDesktop)
        XCTAssertEqual(storedSnapshot?.presentation, .desktop)
        XCTAssertEqual(storedSnapshot?.state.queue.currentItem, items[0].id)
        XCTAssertTrue(storedSnapshot?.isValid == true)

        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testShutdownDuringReturnPersistsPlayerDestination() async throws {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        let didEnterDesktop = await fixture.desktopSession.enterDesktopAndWait()
        XCTAssertTrue(didEnterDesktop)

        fixture.engine.blockPlayerAttachment()
        fixture.desktopSession.returnToPlayer()
        await waitUntil {
            if case .switching(_, destination: .player) =
                fixture.playback.presentation {
                return true
            }
            return false
        }

        await fixture.controller.prepareForShutdown()
        let storedSnapshot = await store.value()

        XCTAssertTrue(fixture.desktopSession.isActive)
        XCTAssertEqual(storedSnapshot?.presentation, .player)

        fixture.engine.finishBlockedPlayerAttachment()
        await waitUntil {
            !fixture.desktopSession.isTransitioning
        }
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testOrdinarySaveFailureKeepsLastKnownGoodSnapshot() async throws {
        let items = makeItems()
        let lastKnownGood = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 7,
            isPlaying: false,
            presentation: .player
        )
        let store = MemoryPlaybackSessionStore(snapshot: lastKnownGood)
        await store.setSaveFailure(true)
        let fixture = makeFixture(items: items, store: store)

        await prepareActiveQueue(items[0], in: fixture)
        await waitUntil {
            fixture.controller.persistenceFailure == .saveFailed
        }
        _ = await waitForPersistenceToSettle(in: store)
        let preservedSnapshot = await store.value()
        let clearCount = await store.clearCount
        let failedSaveCount = await store.saveCount
        for _ in 0..<64 {
            await Task.yield()
        }
        let saveCountAfterObservation = await store.saveCount

        XCTAssertEqual(preservedSnapshot, lastKnownGood)
        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(saveCountAfterObservation, failedSaveCount)
        XCTAssertEqual(fixture.controller.persistenceFailure, .saveFailed)

        await shutdown(fixture)
    }

    func testTemporaryRestorePreservesSnapshotAndPermanentFailureClearsIt()
        async throws
    {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 11,
            isPlaying: true,
            presentation: .player
        )
        let temporaryStore = MemoryPlaybackSessionStore(snapshot: snapshot)
        let temporaryFixture = makeFixture(
            items: [],
            scannedRoots: [],
            store: temporaryStore
        )

        let temporaryResult = await restoreStoredSession(
            in: temporaryFixture
        )
        let changedRate = try XCTUnwrap(PlaybackPolicy.supportedRates.last)
        temporaryFixture.playback.setRate(changedRate)
        await temporaryFixture.controller.prepareForShutdown()
        let preservedSnapshot = await temporaryStore.value()

        XCTAssertEqual(temporaryResult, .temporarilyUnavailable)
        XCTAssertEqual(preservedSnapshot, snapshot)

        temporaryFixture.desktopSession.shutdown()
        await temporaryFixture.library.shutdown()

        let permanentStore = MemoryPlaybackSessionStore(snapshot: snapshot)
        let permanentFixture = makeFixture(
            items: [],
            scannedRoots: [
                MediaLibraryRoot(
                    url: items[0].rootURL,
                    displayName: "Library"
                )
            ],
            store: permanentStore
        )

        let permanentResult = await restoreStoredSession(in: permanentFixture)
        let clearedSnapshot = await permanentStore.value()
        let permanentClearCount = await permanentStore.clearCount

        XCTAssertEqual(permanentResult, .permanentlyUnavailable)
        XCTAssertNil(clearedSnapshot)
        XCTAssertEqual(permanentClearCount, 1)

        await shutdown(permanentFixture)
    }

    func testQueueMutationReplacesDeferredRestorePlan() async throws {
        let availableItem = makeItems()[0]
        let missingRootURL = URL(
            fileURLWithPath: "/Volumes/Muralume Missing Library",
            isDirectory: true
        )
        let missingItem = makeItem(
            rootURL: missingRootURL,
            name: "Missing",
            path: "missing.mp4"
        )
        let snapshot = try makeSnapshot(
            items: [missingItem],
            currentItem: missingItem,
            currentTime: 11,
            isPlaying: true,
            presentation: .desktop
        )
        let fixture = makeFixture(
            items: [availableItem],
            snapshot: snapshot,
            hasUnavailablePersistedSources: true
        )

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .temporarilyUnavailable)
        XCTAssertTrue(fixture.controller.hasDeferredRestorePlan)

        fixture.library.play(availableItem)
        await waitUntil {
            fixture.playback.readiness == .ready
        }

        XCTAssertFalse(fixture.controller.hasDeferredRestorePlan)

        await shutdown(fixture)
    }

    func testShutdownFlushesFirstQueueWhileCheckpointIsPending() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let delayedPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .seconds(3_600),
            minimumSnapshotSaveInterval: .zero,
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: delayedPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)

        await fixture.controller.prepareForShutdown()
        let snapshot = await store.value()
        let saveCount = await store.saveCount

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(snapshot?.state.queue.currentItem, items[0].id)
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testExternalPlaybackPreservesLastKnownGoodOnExplicitSaveAndShutdown()
        async throws {
        let items = makeItems()
        let lastKnownGood = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 11,
            isPlaying: false,
            presentation: .player
        )
        let store = MemoryPlaybackSessionStore(snapshot: lastKnownGood)
        let delayedPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .seconds(3_600),
            minimumSnapshotSaveInterval: .zero,
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: delayedPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        let initialSaveCount = await waitForPersistenceToSettle(in: store)
        XCTAssertEqual(initialSaveCount, 0)

        let didOpen = await fixture.library.openFilesTemporarily([
            items[1].url,
            items[0].url
        ])
        await waitUntil {
            fixture.library.isExternalPlaybackContext
                && fixture.playback.readiness == .ready
        }
        fixture.playback.seek(to: 37)
        fixture.controller.preserveCurrentSnapshot()
        let saveCountAfterExplicitRequest =
            await waitForPersistenceToSettle(in: store)
        let snapshotAfterExplicitRequest = await store.value()

        XCTAssertTrue(didOpen)
        XCTAssertEqual(fixture.library.currentItemID, items[1].id)
        XCTAssertEqual(saveCountAfterExplicitRequest, initialSaveCount)
        XCTAssertEqual(snapshotAfterExplicitRequest, lastKnownGood)

        await fixture.controller.prepareForShutdown()
        let finalSaveCount = await store.saveCount
        let finalClearCount = await store.clearCount
        let finalSnapshot = await store.value()

        XCTAssertEqual(finalSaveCount, initialSaveCount)
        XCTAssertEqual(finalClearCount, 0)
        XCTAssertEqual(finalSnapshot, lastKnownGood)
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testPersistenceResumesAfterRestoringExternalPlaybackContext()
        async throws {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        _ = await waitForPersistenceToSettle(in: store)
        let context = try XCTUnwrap(
            fixture.library.capturePlaybackContext()
        )

        let didOpen = await fixture.library.openFilesTemporarily([
            items[1].url,
            items[0].url
        ])
        await waitUntil {
            fixture.library.isExternalPlaybackContext
                && fixture.playback.readiness == .ready
        }
        XCTAssertTrue(didOpen)
        let restoreResult = await fixture.library.restorePlaybackContext(
            context
        )
        let saveCountAfterRestore =
            await waitForPersistenceToSettle(in: store)

        XCTAssertEqual(restoreResult, .restored)
        XCTAssertFalse(fixture.library.isExternalPlaybackContext)
        XCTAssertEqual(fixture.library.currentItemID, items[0].id)

        XCTAssertTrue(fixture.library.playNext())
        await waitForSave(after: saveCountAfterRestore, in: store)
        let storedSnapshot = await store.value()

        XCTAssertEqual(
            storedSnapshot?.state.queue.currentItem,
            items[1].id
        )
        await shutdown(fixture)
    }

    func testCoalescedQueueChangesFlushOnlyLatestSnapshotAtShutdown() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let delayedPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .seconds(3_600),
            minimumSnapshotSaveInterval: .zero,
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: delayedPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)

        _ = fixture.library.playNext()
        fixture.library.playPrevious()
        _ = fixture.library.playNext()
        for _ in 0..<32 {
            await Task.yield()
        }

        let saveCountBeforeShutdown = await store.saveCount
        XCTAssertEqual(saveCountBeforeShutdown, 0)

        await fixture.controller.prepareForShutdown()
        let snapshot = await store.value()

        let saveCountAfterShutdown = await store.saveCount
        XCTAssertEqual(saveCountAfterShutdown, 1)
        XCTAssertEqual(snapshot?.state.queue.currentItem, items[1].id)
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testIdenticalExplicitSnapshotDoesNotReachStoreTwice() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        let settledSaveCount = await waitForPersistenceToSettle(in: store)

        fixture.controller.preserveCurrentSnapshot()
        let finalSaveCount = await waitForPersistenceToSettle(in: store)

        XCTAssertEqual(finalSaveCount, settledSaveCount)
        await shutdown(fixture)
    }

    func testSaveFailureBackoffDoesNotRetryForEveryProgressTick() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        await store.setSaveFailure(true)
        let backoffPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .zero,
            minimumSnapshotSaveInterval: .zero,
            progressSaveDelay: .zero,
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: backoffPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        await waitUntil {
            fixture.controller.persistenceFailure == .saveFailed
        }
        let failedSaveCount = await store.saveCount

        fixture.playback.seek(to: 1)
        fixture.playback.seek(to: 2)
        fixture.playback.seek(to: 3)
        for _ in 0..<32 {
            await Task.yield()
        }

        let saveCountAfterProgress = await store.saveCount
        XCTAssertEqual(saveCountAfterProgress, failedSaveCount)
        await shutdown(fixture)
    }

    func testCriticalStateChangeIgnoresQueueCheckpointInterval() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let checkpointPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .zero,
            minimumSnapshotSaveInterval: .seconds(3_600),
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: checkpointPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        let initialSaveCount = await waitForPersistenceToSettle(in: store)

        fixture.playback.setPlaybackIntent(.paused)
        await waitForSave(after: initialSaveCount, in: store)
        let snapshot = await store.value()

        XCTAssertFalse(snapshot?.state.isPlaybackRequested == true)
        await shutdown(fixture)
    }

    func testQueueStructureChangeIgnoresCursorCheckpointInterval() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let checkpointPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .zero,
            minimumSnapshotSaveInterval: .seconds(3_600),
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .seconds(3_600)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: checkpointPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        let initialSaveCount = await waitForPersistenceToSettle(in: store)

        fixture.library.setPlaybackOrder(.shuffled)
        await waitForSave(after: initialSaveCount, in: store)
        let snapshot = await store.value()

        XCTAssertEqual(snapshot?.state.queue.order, .shuffled)
        await shutdown(fixture)
    }

    func testGenericSaveFailureAutomaticallyRetriesWithoutPublisher()
        async throws
    {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let retryPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .zero,
            minimumSnapshotSaveInterval: .seconds(3_600),
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .milliseconds(50)
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: retryPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        _ = await waitForPersistenceToSettle(in: store)
        await store.setSaveFailure(true)

        let changedRate = try XCTUnwrap(PlaybackPolicy.supportedRates.last)
        fixture.playback.setRate(changedRate)
        await waitUntil {
            fixture.controller.persistenceFailure == .saveFailed
        }
        let failedSaveCount = await store.saveCount

        // Store recovery is intentionally not accompanied by another model
        // publisher; the controller's backoff task must drive this retry.
        await store.setSaveFailure(false)
        try? await Task.sleep(for: .milliseconds(100))
        await waitForSave(after: failedSaveCount, in: store)
        let snapshot = await store.value()

        XCTAssertEqual(snapshot?.state.playbackRate, changedRate)
        XCTAssertNil(fixture.controller.persistenceFailure)
        await shutdown(fixture)
    }

    func testHighestPendingUrgencyPersistsStateChangedDuringStoreWrite()
        async throws
    {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let checkpointPolicy = PlaybackSessionPersistencePolicy(
            stateChangeCoalescingDelay: .zero,
            minimumSnapshotSaveInterval: .seconds(3_600),
            progressSaveDelay: .seconds(3_600),
            failureRetryDelay: .zero
        )
        let fixture = makeFixture(
            items: items,
            store: store,
            persistencePolicy: checkpointPolicy
        )
        await prepareActiveQueue(items[0], in: fixture)
        _ = await waitForPersistenceToSettle(in: store)
        await store.setBlockSave(true)

        fixture.playback.seek(to: 1)
        fixture.controller.preserveCurrentSnapshot()
        for _ in 0..<1_000 {
            if await store.didBeginBlockedSave {
                break
            }
            await Task.yield()
        }
        let didBeginBlockedSave = await store.didBeginBlockedSave
        XCTAssertTrue(didBeginBlockedSave)
        let blockedSaveCount = await store.saveCount

        fixture.playback.setPlaybackIntent(.paused)
        // Progress arrives last but must not downgrade the pending critical
        // state urgency to the one-hour checkpoint interval above.
        fixture.playback.seek(to: 5)
        await store.finishBlockedSave()
        await waitForSave(after: blockedSaveCount, in: store)
        let snapshot = await store.value()

        XCTAssertEqual(snapshot?.state.currentTime, 5)
        XCTAssertFalse(snapshot?.state.isPlaybackRequested == true)
        await shutdown(fixture)
    }

    func testContentLimitFailureRetriesOnlyAfterQueueStructureChanges() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        await store.setSaveContentError(
            .fileTooLarge(maximumByteCount: 1, observedByteCount: 2)
        )
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        await waitUntil {
            fixture.controller.persistenceFailure == .saveFailed
        }
        let rejectedSaveCount = await waitForPersistenceToSettle(in: store)

        fixture.playback.seek(to: 1)
        fixture.playback.seek(to: 2)
        for _ in 0..<32 {
            await Task.yield()
        }
        let saveCountAfterProgress = await store.saveCount
        XCTAssertEqual(saveCountAfterProgress, rejectedSaveCount)

        let blockedStructureRevision = fixture.library.queueStructureRevision
        _ = fixture.library.playNext()
        for _ in 0..<32 {
            await Task.yield()
        }
        let saveCountAfterCursorChange = await store.saveCount
        XCTAssertEqual(saveCountAfterCursorChange, rejectedSaveCount)
        XCTAssertEqual(
            fixture.library.queueStructureRevision,
            blockedStructureRevision
        )

        await store.setSaveContentError(nil)
        fixture.library.setPlaybackOrder(.shuffled)
        XCTAssertEqual(
            fixture.library.queueStructureRevision,
            blockedStructureRevision + 1
        )
        await waitForSave(after: saveCountAfterCursorChange, in: store)

        XCTAssertNil(fixture.controller.persistenceFailure)
        await shutdown(fixture)
    }

#if DEBUG
    func testQueueRevisionBuildsOneSnapshotForScheduledPersistence() async {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        let settledSaveCount = await waitForPersistenceToSettle(in: store)
        let initialSnapshotCount =
            fixture.controller.queueSnapshotConstructionCount
        let initialRevision = fixture.library.queueRevision

        fixture.library.setPlaybackOrder(.shuffled)
        await waitForSave(after: settledSaveCount, in: store)
        let finalSaveCount = await waitForPersistenceToSettle(in: store)

        XCTAssertEqual(fixture.library.queueRevision, initialRevision + 1)
        XCTAssertEqual(finalSaveCount - settledSaveCount, 1)
        XCTAssertEqual(
            fixture.controller.queueSnapshotConstructionCount
                - initialSnapshotCount,
            1
        )

        await shutdown(fixture)
    }
#endif

    private func restoreStoredSession(
        in fixture: PlaybackSessionFixture
    ) async -> PlaybackStateRestoreResult {
        let planResult = await fixture.controller.makeRestorePlan()
        guard case let .restore(plan) = planResult else {
            XCTFail("Expected a restorable playback session, got \(planResult)")
            return .cancelled
        }

        return await fixture.controller.restore(
            plan,
            after: fixture.library.start()
        )
    }

    private func prepareActiveQueue(
        _ item: LibraryMediaItem,
        in fixture: PlaybackSessionFixture
    ) async {
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(item)
        await waitUntil {
            fixture.playback.readiness == .ready
        }
    }

    private func shutdown(_ fixture: PlaybackSessionFixture) async {
        await fixture.controller.prepareForShutdown()
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for playback session state.")
    }

    private func waitForSave(
        after saveCount: Int,
        in store: MemoryPlaybackSessionStore
    ) async {
        for _ in 0..<1_000 {
            if await store.saveCount > saveCount {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for playback session persistence.")
    }

    private func waitForPersistenceToSettle(
        in store: MemoryPlaybackSessionStore
    ) async -> Int {
        var lastSaveCount = await store.saveCount
        var stableYieldCount = 0
        for _ in 0..<1_000 {
            await Task.yield()
            let saveCount = await store.saveCount
            if saveCount == lastSaveCount {
                stableYieldCount += 1
                if stableYieldCount == 16 {
                    return saveCount
                }
            } else {
                lastSaveCount = saveCount
                stableYieldCount = 0
            }
        }
        XCTFail("Timed out waiting for playback session persistence to settle.")
        return lastSaveCount
    }

    private func makeFixture(
        items: [LibraryMediaItem],
        scannedRoots: [MediaLibraryRoot]? = nil,
        snapshot: PlaybackSessionSnapshot? = nil,
        store suppliedStore: MemoryPlaybackSessionStore? = nil,
        hasUnavailablePersistedSources: Bool = false,
        persistencePolicy: PlaybackSessionPersistencePolicy = .immediate
    ) -> PlaybackSessionFixture {
        let rootURL = makeItems()[0].rootURL
        let engine = SessionPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        let library = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: SessionSourceSelector(),
            mediaSession: SessionMediaAccessSession(
                rootURLs: [rootURL],
                hasUnavailablePersistedSources:
                    hasUnavailablePersistedSources
            ),
            scanner: SessionMediaScanner(
                snapshot: MediaLibrarySnapshot(
                    roots: scannedRoots ?? [
                        MediaLibraryRoot(
                            url: rootURL,
                            displayName: "Library"
                        )
                    ],
                    items: items
                )
            ),
            mediaThumbnailProvider: TestMediaThumbnailProvider(),
            playbackOrder: .ordered
        )
        let applicationPresence = TestApplicationPresenceController()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: TestDesktopHost(),
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: applicationPresence
        )
        let store = suppliedStore
            ?? MemoryPlaybackSessionStore(snapshot: snapshot)
        let controller = PlaybackSessionController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: store,
            persistencePolicy: persistencePolicy
        )
        return PlaybackSessionFixture(
            controller: controller,
            library: library,
            playback: playback,
            desktopSession: desktopSession,
            engine: engine,
            applicationPresence: applicationPresence,
            playerSurface: playerSurface
        )
    }

    private func makeItems() -> [LibraryMediaItem] {
        let rootURL = URL(
            fileURLWithPath: "/tmp/PlaybackSessionControllerTests/Library"
        )
        return [
            makeItem(rootURL: rootURL, name: "First", path: "first.mp4"),
            makeItem(rootURL: rootURL, name: "Second", path: "second.mp4")
        ]
    }

    private func makeItem(
        rootURL: URL,
        name: String,
        path: String
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent(path),
            displayName: name,
            relativePath: path,
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
    }

    private func makeSnapshot(
        items: [LibraryMediaItem],
        currentItem: LibraryMediaItem,
        currentTime: TimeInterval,
        isPlaying: Bool,
        presentation: PlaybackSessionPresentation,
        videoContentMode: DesktopVideoContentMode = .cover
    ) throws -> PlaybackSessionSnapshot {
        let queue = PlaybackQueue(
            items: items.map(\.id),
            startingAt: currentItem.id,
            order: .ordered
        )
        return PlaybackSessionSnapshot(
            state: DesktopPreset(
                queue: try XCTUnwrap(queue.makeSnapshot()),
                currentTime: currentTime,
                isPlaybackRequested: isPlaying,
                playbackRate: PlaybackPolicy.defaultRate,
                videoContentMode: videoContentMode
            ),
            presentation: presentation
        )
    }
}

@MainActor
private struct PlaybackSessionFixture {
    let controller: PlaybackSessionController
    let library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let engine: SessionPlaybackEngine
    let applicationPresence: TestApplicationPresenceController
    // PlaybackCoordinator retains render surfaces weakly.
    let playerSurface: TestPlaybackSurface
}

@MainActor
private final class SessionSourceSelector: MediaSourceSelecting {
    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL] {
        []
    }
}

@MainActor
private final class SessionMediaAccessSession: MediaAccessSession {
    private let rootURLs: [URL]
    let hasUnavailablePersistedSources: Bool

    init(
        rootURLs: [URL],
        hasUnavailablePersistedSources: Bool
    ) {
        self.rootURLs = rootURLs
        self.hasUnavailablePersistedSources =
            hasUnavailablePersistedSources
    }

    func restoreFolders() -> [URL] {
        rootURLs
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        rootURLs
    }

    func removeFolder(_ url: URL) -> [URL] {
        rootURLs.filter { $0 != url }
    }

    func stop() {}
}

private final class SessionMediaScanner:
    MediaLibraryScanning,
    @unchecked Sendable
{
    private let snapshot: MediaLibrarySnapshot

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        snapshot
    }
}

@MainActor
private final class SessionPlaybackEngine: PlaybackEngine {
    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?

    private(set) var attachedSurfaceIDs: [PlaybackSurfaceID] = []
    private(set) var soughtTimes: [TimeInterval] = []
    private(set) var playCallCount = 0
    private(set) var isPlaying = false
    private var shouldBlockPlayerAttachment = false
    private var playerAttachmentContinuation:
        CheckedContinuation<Void, Never>?

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        120
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        attachedSurfaceIDs.append(surface.id)
        guard surface.id == .player,
              shouldBlockPlayerAttachment else {
            return
        }
        await withCheckedContinuation { continuation in
            playerAttachmentContinuation = continuation
        }
    }

    func blockPlayerAttachment() {
        shouldBlockPlayerAttachment = true
    }

    func finishBlockedPlayerAttachment() {
        shouldBlockPlayerAttachment = false
        playerAttachmentContinuation?.resume()
        playerAttachmentContinuation = nil
    }

    func detachAll() {}

    func play(at rate: PlaybackRate) {
        playCallCount += 1
        isPlaying = true
        playbackActivityHandler?(true)
    }

    func pause() {
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {
        soughtTimes.append(seconds)
    }

    func setVolume(_ volume: PlaybackVolume) {}

    func setMuted(_ isMuted: Bool) {}

    func stop() {
        isPlaying = false
        playbackActivityHandler?(false)
    }
}

private enum MemoryPlaybackSessionStoreError: Error {
    case saveFailed
}

private actor MemoryPlaybackSessionStore: PlaybackSessionStoring {
    private var snapshot: PlaybackSessionSnapshot?
    private var loadError: PlaybackSessionStoreError?
    private var saveContentError: PlaybackSessionStoreError?
    private var shouldFailSave = false
    private var shouldBlockSave = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var didBeginBlockedSave = false
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(snapshot: PlaybackSessionSnapshot?) {
        self.snapshot = snapshot
    }

    func setSaveFailure(_ shouldFail: Bool) {
        shouldFailSave = shouldFail
    }

    func setLoadError(_ error: PlaybackSessionStoreError?) {
        loadError = error
    }

    func setSaveContentError(_ error: PlaybackSessionStoreError?) {
        saveContentError = error
    }

    func setBlockSave(_ shouldBlock: Bool) {
        shouldBlockSave = shouldBlock
    }

    func finishBlockedSave() {
        shouldBlockSave = false
        blockedSaveContinuation?.resume()
        blockedSaveContinuation = nil
    }

    func value() -> PlaybackSessionSnapshot? {
        snapshot
    }

    func load() throws -> PlaybackSessionSnapshot? {
        if let loadError {
            throw loadError
        }
        return snapshot
    }

    func save(_ snapshot: PlaybackSessionSnapshot) async throws {
        saveCount += 1
        if shouldBlockSave {
            didBeginBlockedSave = true
            await withCheckedContinuation { continuation in
                blockedSaveContinuation = continuation
            }
        }
        if let saveContentError {
            throw saveContentError
        }
        if shouldFailSave {
            throw MemoryPlaybackSessionStoreError.saveFailed
        }
        self.snapshot = snapshot
    }

    func clear() {
        clearCount += 1
        snapshot = nil
    }
}
