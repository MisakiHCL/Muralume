import Combine
import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistTests: XCTestCase {
    func testCreatesUserNamedPlaylistsAndRejectsEquivalentNames() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var collection = CustomPlaylistCollection.empty

        let travelID = try collection.createPlaylist(
            named: "  旅行  ",
            now: now
        )
        let skyID = try collection.createPlaylist(named: "天空", now: now)

        XCTAssertEqual(collection.playlists.map(\.name), ["旅行", "天空"])
        XCTAssertEqual(collection.playlist(id: travelID)?.createdAt, now)
        XCTAssertNotEqual(travelID, skyID)
        XCTAssertThrowsError(try collection.createPlaylist(named: "旅行")) {
            XCTAssertEqual(
                $0 as? CustomPlaylistMutationError,
                .duplicateName
            )
        }
        XCTAssertThrowsError(try collection.createPlaylist(named: "   ")) {
            XCTAssertEqual(
                $0 as? CustomPlaylistMutationError,
                .invalidName
            )
        }
    }

    func testAddsEachMediaOnceAndPreservesUserOrder() throws {
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "旅行")
        let tokyo = makeItem(name: "Tokyo", relativePath: "Tokyo.mp4")
        let kyoto = makeItem(name: "Kyoto", relativePath: "Kyoto.mp4")

        XCTAssertEqual(
            try collection.add(
                items: [tokyo, kyoto, tokyo],
                to: playlistID
            ),
            2
        )
        let entries = try XCTUnwrap(
            collection.playlist(id: playlistID)?.entries
        )
        let playlist = try XCTUnwrap(
            collection.playlist(id: playlistID)
        )
        XCTAssertTrue(playlist.contains(mediaItem: tokyo))
        XCTAssertTrue(playlist.contains(mediaItem: kyoto))
        XCTAssertEqual(
            entries.map(\.media.lastKnownDisplayName),
            ["Tokyo", "Kyoto"]
        )

        try collection.moveEntry(
            entries[1].id,
            before: entries[0].id,
            in: playlistID
        )
        XCTAssertEqual(
            collection.playlist(id: playlistID)?.entries.map(
                \.media.lastKnownDisplayName
            ),
            ["Kyoto", "Tokyo"]
        )
    }

    func testMoveToSelfOrUnknownDestinationDoesNotMutatePlaylist() throws {
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "旅行")
        let first = makeItem(name: "Tokyo", relativePath: "Tokyo.mp4")
        let second = makeItem(name: "Kyoto", relativePath: "Kyoto.mp4")
        try collection.add(items: [first, second], to: playlistID)
        let originalPlaylist = try XCTUnwrap(
            collection.playlist(id: playlistID)
        )
        let firstEntryID = try XCTUnwrap(originalPlaylist.entries.first?.id)

        try collection.moveEntry(
            firstEntryID,
            before: firstEntryID,
            in: playlistID
        )
        try collection.moveEntry(
            firstEntryID,
            before: CustomPlaylistEntry.ID(),
            in: playlistID
        )

        XCTAssertEqual(collection.playlist(id: playlistID), originalPlaylist)
    }

    func testValidationRejectsDuplicatePersistedMediaReferences() {
        let item = makeItem(name: "Tokyo", relativePath: "Tokyo.mp4")
        let reference = MediaReference(item: item)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let playlist = CustomPlaylist(
            name: "旅行",
            entries: [
                CustomPlaylistEntry(media: reference),
                CustomPlaylistEntry(media: reference)
            ],
            createdAt: date,
            updatedAt: date
        )

        XCTAssertFalse(
            CustomPlaylistCollection(playlists: [playlist]).isValid
        )
    }

    func testRenameReconcilesUniqueFileIdentityWithoutDroppingOfflineEntries()
        throws {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([1]),
            fileIdentifier: Data([2])
        )
        let original = makeItem(
            name: "Clouds",
            relativePath: "Old/Clouds.mp4",
            identity: identity
        )
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "天空")
        try collection.add(items: [original], to: playlistID)

        let renamed = makeItem(
            name: "Blue Sky",
            relativePath: "New/Blue Sky.mp4",
            identity: identity
        )
        XCTAssertTrue(
            collection.reconcile(
                using: [renamed],
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        let updatedReference = try XCTUnwrap(
            collection.playlist(id: playlistID)?.entries.first?.media
        )
        XCTAssertEqual(updatedReference.mediaItemID, renamed.id)
        XCTAssertEqual(updatedReference.lastKnownDisplayName, "Blue Sky")
        XCTAssertTrue(
            try XCTUnwrap(collection.playlist(id: playlistID))
                .contains(mediaItem: renamed)
        )

        XCTAssertFalse(collection.reconcile(using: []))
        XCTAssertEqual(
            collection.playlist(id: playlistID)?.entries.count,
            1
        )
        XCTAssertTrue(
            collection.resolvedItems(in: playlistID, using: []).isEmpty
        )
    }

    func testAmbiguousFileIdentityDoesNotRelinkReference() throws {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([3]),
            fileIdentifier: Data([4])
        )
        let original = makeItem(
            name: "Original",
            relativePath: "Original.mp4",
            identity: identity
        )
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "天空")
        try collection.add(items: [original], to: playlistID)

        let firstHardLink = makeItem(
            name: "First",
            relativePath: "First.mp4",
            identity: identity
        )
        let secondHardLink = makeItem(
            name: "Second",
            relativePath: "Second.mp4",
            identity: identity
        )

        XCTAssertFalse(
            collection.reconcile(using: [firstHardLink, secondHardLink])
        )
        XCTAssertTrue(
            collection.resolvedItems(
                in: playlistID,
                using: [firstHardLink, secondHardLink]
            ).isEmpty
        )
    }

    func testExactPathClaimPreventsRenameIdentityCollision() throws {
        let firstIdentity = MediaFileIdentity(
            volumeIdentifier: Data([11]),
            fileIdentifier: Data([12])
        )
        let secondIdentity = MediaFileIdentity(
            volumeIdentifier: Data([13]),
            fileIdentifier: Data([14])
        )
        let first = makeItem(
            name: "First",
            relativePath: "A.mp4",
            identity: firstIdentity
        )
        let second = makeItem(
            name: "Second",
            relativePath: "B.mp4",
            identity: secondIdentity
        )
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "Collision")
        try collection.add(items: [first, second], to: playlistID)

        let firstRenamedOverSecond = makeItem(
            name: "First renamed",
            relativePath: "B.mp4",
            identity: firstIdentity
        )
        XCTAssertTrue(
            collection.reconcile(using: [firstRenamedOverSecond])
        )

        let playlist = try XCTUnwrap(collection.playlist(id: playlistID))
        XCTAssertTrue(collection.isValid)
        XCTAssertEqual(
            collection.resolvedItems(
                in: playlistID,
                using: [firstRenamedOverSecond]
            ).map(\.id),
            [firstRenamedOverSecond.id]
        )
        XCTAssertEqual(playlist.entries[0].media.fileIdentity, firstIdentity)
        XCTAssertEqual(playlist.entries[1].media.fileIdentity, secondIdentity)
    }

    func testQueueIdentityFallbackNeverCollapsesTwoHistoricalItems() {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([7]),
            fileIdentifier: Data([8])
        )
        let firstOldItem = makeItem(
            name: "First old item",
            relativePath: "Old/A.mp4",
            identity: identity
        )
        let secondOldItem = makeItem(
            name: "Second old item",
            relativePath: "Old/B.mp4",
            identity: identity
        )
        let renamedItem = makeItem(
            name: "Renamed item",
            relativePath: "New/Renamed.mp4",
            identity: identity
        )

        let resolution = MediaReferenceResolutionIndex(items: [renamedItem])
            .resolveQueuedItems([
                firstOldItem.id: firstOldItem,
                secondOldItem.id: secondOldItem
            ])

        XCTAssertEqual(resolution.resolvedItemsByQueuedID.count, 2)
        XCTAssertEqual(resolution.canonicalItemsByID.count, 2)
        XCTAssertEqual(
            Set(resolution.resolvedItemsByQueuedID.values.map(\.id)),
            Set([renamedItem.id, secondOldItem.id])
        )
    }

    func testQueueExactPathClaimWinsOverIdentityFallback() {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([9]),
            fileIdentifier: Data([10])
        )
        let exactItem = makeItem(
            name: "Current path",
            relativePath: "Current.mp4",
            identity: identity
        )
        let historicalItem = makeItem(
            name: "Historical path",
            relativePath: "Historical.mp4",
            identity: identity
        )

        let resolution = MediaReferenceResolutionIndex(items: [exactItem])
            .resolveQueuedItems([
                exactItem.id: exactItem,
                historicalItem.id: historicalItem
            ])

        XCTAssertEqual(
            resolution.resolvedItemsByQueuedID[exactItem.id]?.id,
            exactItem.id
        )
        XCTAssertEqual(
            resolution.resolvedItemsByQueuedID[historicalItem.id]?.id,
            historicalItem.id
        )
    }

    func testFileStoreRoundTripsAndRejectsOversizedInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("playlists.json")
        let store = FileCustomPlaylistStore(fileURL: fileURL)
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "旅行")
        try collection.add(
            items: [makeItem(name: "Tokyo", relativePath: "Tokyo.mp4")],
            to: playlistID
        )

        try await store.save(collection)
        let restoredCollection = try await store.load()
        XCTAssertEqual(restoredCollection, collection)

        let boundedStore = FileCustomPlaylistStore(
            fileURL: directory.appendingPathComponent("bounded.json"),
            maximumFileByteCount: 1
        )
        do {
            try await boundedStore.save(collection)
            XCTFail("Expected the bounded store to reject the collection")
        } catch let error as CustomPlaylistStoreError {
            guard case .fileTooLarge = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
    }

    func testFileStoreRejectsCorruptionAndUnknownSchemaWithoutOverwriting()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("playlists.json")
        let store = FileCustomPlaylistStore(fileURL: fileURL)
        let corruptedData = Data("{not-json".utf8)
        try corruptedData.write(to: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected corrupted JSON to fail loading")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fileURL), corruptedData)
        }

        let unknownSchemaData = Data(
            #"{"schemaVersion":999,"playlists":[]}"#.utf8
        )
        try unknownSchemaData.write(to: fileURL)
        do {
            _ = try await store.load()
            XCTFail("Expected an unknown schema to fail validation")
        } catch let error as CustomPlaylistStoreError {
            XCTAssertEqual(error, .invalidCollection)
            XCTAssertEqual(try Data(contentsOf: fileURL), unknownSchemaData)
        }
    }

    func testFileStoreRejectsOversizedLoadAndInvalidSavePreservesOldData()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("playlists.json")
        let boundedStore = FileCustomPlaylistStore(
            fileURL: fileURL,
            maximumFileByteCount: 8
        )
        try Data(repeating: 1, count: 9).write(to: fileURL)
        do {
            _ = try await boundedStore.load()
            XCTFail("Expected oversized persisted input to fail")
        } catch let error as CustomPlaylistStoreError {
            XCTAssertEqual(
                error,
                .fileTooLarge(maximumByteCount: 8, observedByteCount: 9)
            )
        }

        let store = FileCustomPlaylistStore(fileURL: fileURL)
        var validCollection = CustomPlaylistCollection.empty
        _ = try validCollection.createPlaylist(named: "旅行")
        try await store.save(validCollection)
        let originalData = try Data(contentsOf: fileURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let duplicate = CustomPlaylist(
            name: "重复",
            createdAt: date,
            updatedAt: date
        )
        let invalidCollection = CustomPlaylistCollection(
            playlists: [duplicate, duplicate]
        )

        do {
            try await store.save(invalidCollection)
            XCTFail("Expected invalid collection to be rejected")
        } catch let error as CustomPlaylistStoreError {
            XCTAssertEqual(error, .invalidCollection)
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        }
    }

    func testControllerCoalescesMutationsAndFlushesOnShutdown() async throws {
        let store = CustomPlaylistStoreSpy()
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()

        _ = try controller.createPlaylist(named: "旅行")
        _ = try controller.createPlaylist(named: "天空")
        await controller.shutdown()

        let savedCollections = await store.savedCollections
        XCTAssertEqual(savedCollections.count, 1)
        XCTAssertEqual(
            savedCollections.last?.playlists.map(\.name),
            ["旅行", "天空"]
        )
    }

    func testControllerKeepsOnlyLatestSnapshotWhileSaveIsInFlight()
        async throws
    {
        let store = CustomPlaylistStoreSpy()
        await store.suspendNextSave()
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()
        let playlistID = try controller.createPlaylist(named: "Initial")
        await store.waitForSuspendedSave()

        for index in 1...100 {
            try controller.renamePlaylist(
                id: playlistID,
                to: "Revision \(index)"
            )
        }
        let shutdownTask = Task {
            await controller.shutdown()
        }
        await Task.yield()
        await store.resumeSave()
        await shutdownTask.value

        let savedCollections = await store.savedCollections
        let wasSaveCancelled = await store.wasSaveCancelled
        XCTAssertFalse(wasSaveCancelled)
        XCTAssertEqual(savedCollections.count, 2)
        XCTAssertEqual(savedCollections.first?.playlists.map(\.name), ["Initial"])
        XCTAssertEqual(
            savedCollections.last?.playlists.map(\.name),
            ["Revision 100"]
        )
    }

    func testPlaylistMutationDoesNotPoisonLatestDetailSearchDuringWillSet() async throws {
        let controller = CustomPlaylistController(store: CustomPlaylistStoreSpy())
        await controller.startAndWait()
        let playlistID = try controller.createPlaylist(named: "Favorites")
        let matchingItem = makeItem(name: "Northern Sky", relativePath: "Northern Sky.mov")
        let search = LatestMediaSearch<CustomPlaylistDetailProjection>(
            hasSameContent: CustomPlaylistDetailProjection.hasSameContent
        )
        func request() -> CustomPlaylistSearchRequestID? {
            guard let playlist = controller.collection.playlist(id: playlistID) else { return nil }
            let key = CustomPlaylistSearchRequestID(
                playlistID: playlistID, playlistRevision: controller.collectionRevision,
                libraryItemsRevision: 1, query: "northern sky"
            )
            search.request(key: key, operation: controller.detailSearchOperation(
                for: playlist, query: key.query, using: [matchingItem], itemsRevision: 1
            ))
            return key
        }
        let initialKey = try XCTUnwrap(request())
        await search.waitForPendingSearch()
        XCTAssertTrue(try XCTUnwrap(search.result(for: initialKey)).entries.isEmpty)

        // A synchronous will-set notification sees one coherent old snapshot.
        // It must not reserve the new key for an operation over the old entries.
        let observation = controller.objectWillChange.sink { _ = request() }
        XCTAssertEqual(try controller.add(items: [matchingItem], to: playlistID), 1)
        let updatedPlaylist = try XCTUnwrap(controller.collection.playlist(id: playlistID))
        let updatedKey = try XCTUnwrap(request())
        await search.waitForPendingSearch()
        let updated = try XCTUnwrap(search.result(for: updatedKey))
        XCTAssertNotEqual(updatedKey, initialKey)
        XCTAssertEqual(updated.entries.map(\.id), updatedPlaylist.entries.map(\.id))
        let entry = try XCTUnwrap(updatedPlaylist.entries.first)
        XCTAssertEqual(updated.resolvedItemsByEntryID[entry.id], matchingItem)
        XCTAssertNil(search.result(for: initialKey))
        withExtendedLifetime(observation) {}
        await controller.shutdown()
    }

    func testControllerCanRetryFailedPersistence() async throws {
        let store = CustomPlaylistStoreSpy()
        await store.setSaveFailure(true)
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()
        _ = try controller.createPlaylist(named: "旅行")
        await waitUntil { controller.persistenceFailure == .saveFailed }

        await store.setSaveFailure(false)
        controller.retryPersistence()
        await waitUntil {
            controller.persistenceFailure == nil
                && controller.loadingState == .ready
        }
        await controller.shutdown()

        let savedCollections = await store.savedCollections
        XCTAssertEqual(
            savedCollections.last?.playlists.map(\.name),
            ["旅行"]
        )
    }

    func testControllerRestoresCollectionAcrossInstances() async throws {
        let store = CustomPlaylistStoreSpy()
        let firstController = CustomPlaylistController(store: store)
        await firstController.startAndWait()
        _ = try firstController.createPlaylist(named: "旅行")
        await firstController.shutdown()
        await store.promoteLastSaveToLoadValue()

        let restoredController = CustomPlaylistController(store: store)
        await restoredController.startAndWait()

        XCTAssertEqual(restoredController.playlists.map(\.name), ["旅行"])
        await restoredController.shutdown()
    }

    func testLibraryRevisionReusesIndexAndInvalidatesOffscreenResolvedItems() async throws {
        let controller = CustomPlaylistController(store: CustomPlaylistStoreSpy())
        await controller.startAndWait()
        let item = makeItem(name: "Sky", relativePath: "Sky.mov")
        controller.updateAvailableItems([item], itemsRevision: 1)
        XCTAssertFalse(controller.hasCachedResolutionIndex)
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 0)

        let playlistID = try controller.createPlaylist(named: "Favorites")
        _ = try controller.add(items: [item], to: playlistID)
        await controller.waitForLibraryReconciliation()
        let playlist = try XCTUnwrap(controller.collection.playlist(id: playlistID))
        XCTAssertEqual(controller.resolvedItems(in: playlistID, using: [item], itemsRevision: 1), [item])
        XCTAssertTrue(controller.hasCachedResolvedItems)
        XCTAssertTrue(controller.hasCachedResolutionIndex)
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 1)
        controller.updateAvailableItems([item], itemsRevision: 1)
        XCTAssertEqual(controller.resolvedItems(in: playlistID, using: [item], itemsRevision: 1), [item])
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 1)

        // No consumer read follows this update: old resolved items are released eagerly.
        controller.updateAvailableItems([], itemsRevision: 2)
        XCTAssertFalse(controller.hasCachedResolvedItems)
        await controller.waitForLibraryReconciliation()
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 2)
        XCTAssertTrue(controller.resolvedItems(in: playlistID, using: [], itemsRevision: 2).isEmpty)
        let operation = controller.detailSearchOperation(
            for: playlist, query: "", using: [], itemsRevision: 2
        )
        let result = try await Task.detached { try await operation() }.value
        XCTAssertEqual(result.entries.map(\.id), playlist.entries.map(\.id))
        XCTAssertTrue(result.resolvedItemsByEntryID.isEmpty)
        try controller.renamePlaylist(id: playlistID, to: "Renamed")
        XCTAssertTrue(controller.resolvedItems(in: playlistID, using: [], itemsRevision: 2).isEmpty)
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 2)
        try controller.removePlaylist(id: playlistID)
        XCTAssertFalse(controller.hasCachedResolvedItems)
        XCTAssertFalse(controller.hasCachedResolutionIndex)
        await controller.shutdown()
    }

    func testBackgroundDetailSearchKeepsOfflineEntriesAndResolvedSelection() async throws {
        let controller = CustomPlaylistController(store: CustomPlaylistStoreSpy())
        await controller.startAndWait()
        let first = makeItem(name: "Sky One", relativePath: "Sky One.mov")
        let missing = makeItem(name: "Sky Missing", relativePath: "Sky Missing.mov")
        let second = makeItem(name: "Sky Two", relativePath: "Sky Two.mov")
        let playlistID = try controller.createPlaylist(named: "Sky")
        _ = try controller.add(items: [first, missing, second], to: playlistID)
        let playlist = try XCTUnwrap(controller.collection.playlist(id: playlistID))
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 0)
        let operation = controller.detailSearchOperation(
            for: playlist, query: "sky", using: [first, second], itemsRevision: 1
        )
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 0)
        let result = try await Task.detached { try await operation() }.value
        XCTAssertEqual(result.entries.map(\.id), playlist.entries.map(\.id))
        XCTAssertEqual(result.resolvedItemsByEntryID.count, 2)
        XCTAssertEqual(result.entryID(for: second.id), playlist.entries.last?.id)
        XCTAssertNil(result.resolvedItemsByEntryID[playlist.entries[1].id])
        await controller.shutdown()
    }

    func testLibraryReconciliationCoalescesAndRejectsStaleLibraryAndUserEdits()
        async throws {
        let gate = CustomPlaylistReconciliationGate()
        let controller = CustomPlaylistController(
            store: CustomPlaylistStoreSpy(),
            reconcileOperation: { collection, index in
                await gate.reconcile(
                    collection,
                    using: index,
                    ranOnMainThread: playlistReconciliationIsMainThread()
                )
            }
        )
        await controller.startAndWait()
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([41]), fileIdentifier: Data([42])
        )
        let original = makeItem(name: "Original", relativePath: "Original.mov", identity: identity)
        let first = makeItem(name: "First", relativePath: "First.mov", identity: identity)
        let superseded = makeItem(name: "Superseded", relativePath: "Superseded.mov", identity: identity)
        let latest = makeItem(name: "Latest", relativePath: "Latest.mov", identity: identity)
        let playlistID = try controller.createPlaylist(named: "Favorites")
        try controller.add(items: [original], to: playlistID)
        controller.updateAvailableItems(
            [first], itemsRevision: 1, contentRevision: 1,
            resolutionIndex: MediaReferenceResolutionIndex(items: [first])
        )
        await gate.waitForFirstWorker()
        try controller.renamePlaylist(id: playlistID, to: "User Edited")
        controller.updateAvailableItems(
            [superseded], itemsRevision: 2, contentRevision: 2,
            resolutionIndex: MediaReferenceResolutionIndex(items: [superseded])
        )
        controller.updateAvailableItems(
            [latest], itemsRevision: 3, contentRevision: 3,
            resolutionIndex: MediaReferenceResolutionIndex(items: [latest])
        )
        let callsWhileBlocked = await gate.callCount
        XCTAssertEqual(callsWhileBlocked, 1)
        await gate.releaseFirstWorker()
        await controller.waitForLibraryReconciliation()
        let playlist = try XCTUnwrap(controller.collection.playlist(id: playlistID))
        XCTAssertEqual(playlist.name, "User Edited")
        XCTAssertEqual(playlist.entries.first?.media.mediaItemID, latest.id)
        let calls = await gate.callCount
        let maximumRunning = await gate.maximumRunning
        let ranOnMainThread = await gate.ranOnMainThread
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximumRunning, 1)
        XCTAssertFalse(ranOnMainThread)
        await controller.shutdown()
    }

    func testOrderOnlyLibraryRevisionReusesIndexWithoutReconciliation() async throws {
        let gate = CustomPlaylistReconciliationGate(blocksFirstWorker: false)
        let controller = CustomPlaylistController(
            store: CustomPlaylistStoreSpy(),
            reconcileOperation: { collection, index in
                await gate.reconcile(
                    collection,
                    using: index,
                    ranOnMainThread: playlistReconciliationIsMainThread()
                )
            }
        )
        await controller.startAndWait()
        let first = makeItem(name: "First", relativePath: "First.mov")
        let second = makeItem(name: "Second", relativePath: "Second.mov")
        let playlistID = try controller.createPlaylist(named: "Favorites")
        try controller.add(items: [second, first], to: playlistID)
        let index = MediaReferenceResolutionIndex(items: [first, second])
        controller.updateAvailableItems(
            [first, second], itemsRevision: 1, contentRevision: 1, resolutionIndex: index
        )
        await controller.waitForLibraryReconciliation()
        controller.updateAvailableItems(
            [second, first], itemsRevision: 2, contentRevision: 1, resolutionIndex: index
        )
        await controller.waitForLibraryReconciliation()
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 1)
        XCTAssertEqual(
            controller.resolvedItems(in: playlistID, using: [second, first], itemsRevision: 2),
            [second, first]
        )
        XCTAssertEqual(controller.resolutionIndexRecomputationCount, 1)
        await controller.shutdown()
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for custom playlist persistence")
    }

    private func makeItem(
        name: String,
        relativePath: String,
        identity: MediaFileIdentity? = nil
    ) -> LibraryMediaItem {
        let rootURL = URL(fileURLWithPath: "/Library")
        return LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent(relativePath),
            displayName: name,
            relativePath: relativePath,
            relativeDirectory: URL(fileURLWithPath: relativePath)
                .deletingLastPathComponent()
                .relativePath,
            creationDate: nil,
            fileSize: 1,
            fileIdentity: identity
        )
    }
}

#if DEBUG
@MainActor
final class DebugUITestSessionTests: XCTestCase {
    func testOnlyDedicatedUITestBundleUsesTheSessionEnvironment() throws {
        let root = URL(fileURLWithPath: "/SyntheticUITestTemporaryDirectory")
        let token = UUID().uuidString
        for bundleID in [nil, "com.muralume.Muralume.debug", "com.muralume.Muralume",
                         "com.muralume.Muralume.local", DebugUITestSession.appBundleIdentifier + ".other"] {
            for environment in [[:], [DebugUITestSession.environmentKey: token],
                                [DebugUITestSession.environmentKey: "../invalid"]] {
                XCTAssertNil(try DebugUITestSession.playlistStoreFileURL(
                    bundleIdentifier: bundleID, environment: environment, temporaryDirectory: root
                ))
            }
        }
        let fileURL = try XCTUnwrap(DebugUITestSession.playlistStoreFileURL(
            bundleIdentifier: DebugUITestSession.appBundleIdentifier,
            environment: [DebugUITestSession.environmentKey: token.lowercased()],
            temporaryDirectory: root
        ))
        XCTAssertEqual(fileURL, root.appendingPathComponent(
            "MuralumeUITests/\(token)/custom-playlists.json"
        ))
    }

    func testDedicatedUITestBundleRejectsMissingAndMalformedSessionTokens() {
        XCTAssertThrowsError(try DebugUITestSession.playlistStoreFileURL(
            bundleIdentifier: DebugUITestSession.appBundleIdentifier, environment: [:]
        )) {
            XCTAssertEqual($0 as? DebugUITestSession.ConfigurationError, .missingSessionIdentifier)
        }
        let token = UUID().uuidString
        for value in ["", "../outside", token + "/child", token + "\n",
                      token.replacingOccurrences(of: "-", with: "")] {
            XCTAssertThrowsError(try DebugUITestSession.playlistStoreFileURL(
                bundleIdentifier: DebugUITestSession.appBundleIdentifier,
                environment: [DebugUITestSession.environmentKey: value]
            )) {
                XCTAssertEqual($0 as? DebugUITestSession.ConfigurationError, .invalidSessionIdentifier)
            }
        }
    }

    func testSessionsRestartIndependentlyWithoutReadingOrOverwritingTheDefaultStore()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supportURL = root.appendingPathComponent("ApplicationSupport")
        let defaultStore = FileCustomPlaylistStore(fileManager: PlaylistSessionFileManager(
            applicationSupportDirectory: supportURL
        ))
        var original = CustomPlaylistCollection.empty
        try original.createPlaylist(named: "Existing default playlist")
        try await defaultStore.save(original)
        let defaultFile = supportURL
            .appendingPathComponent("Muralume/custom-playlists.json")
        let originalBytes = try Data(contentsOf: defaultFile)
        let token = UUID().uuidString
        func sessionURL(_ token: String) throws -> URL {
            try XCTUnwrap(DebugUITestSession.playlistStoreFileURL(
                bundleIdentifier: DebugUITestSession.appBundleIdentifier,
                environment: [DebugUITestSession.environmentKey: token],
                temporaryDirectory: root.appendingPathComponent("Temporary")
            ))
        }
        let firstURL = try sessionURL(token)
        let secondURL = try sessionURL(UUID().uuidString)
        XCTAssertNotEqual(firstURL, secondURL)
        let first = FileCustomPlaylistStore(fileURL: firstURL)
        let initial = try await first.load()
        XCTAssertEqual(initial, .empty)
        var created = CustomPlaylistCollection.empty
        try created.createPlaylist(named: "Isolated test playlist")
        try await first.save(created)
        let restartedURL = try sessionURL(token.lowercased())
        XCTAssertEqual(restartedURL, firstURL)
        let restarted = FileCustomPlaylistStore(fileURL: restartedURL)
        let restored = try await restarted.load()
        XCTAssertEqual(restored, created)
        let second = FileCustomPlaylistStore(fileURL: secondURL)
        let otherSession = try await second.load()
        XCTAssertEqual(otherSession, .empty)
        let normalURL = try DebugUITestSession.playlistStoreFileURL(
            bundleIdentifier: "com.muralume.Muralume.debug",
            environment: [DebugUITestSession.environmentKey: token]
        )
        let normal = FileCustomPlaylistStore(
            fileURL: normalURL,
            fileManager: PlaylistSessionFileManager(applicationSupportDirectory: supportURL)
        )
        let normalCollection = try await normal.load()
        XCTAssertEqual(normalCollection, original)
        XCTAssertEqual(try Data(contentsOf: defaultFile), originalBytes)
    }
}

private final class PlaylistSessionFileManager: FileManager, @unchecked Sendable {
    let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory
            ? [applicationSupportDirectory] : super.urls(for: directory, in: domainMask)
    }
}
#endif

private actor CustomPlaylistStoreSpy: CustomPlaylistStoring {
    private var loadValue = CustomPlaylistCollection.empty
    private(set) var savedCollections: [CustomPlaylistCollection] = []
    private var shouldFailSave = false
    private var shouldSuspendNextSave = false
    private var suspendedSave: CheckedContinuation<Void, Never>?
    private var saveSuspensionWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasSaveCancelled = false

    func load() async throws -> CustomPlaylistCollection {
        loadValue
    }

    func save(_ collection: CustomPlaylistCollection) async throws {
        if shouldSuspendNextSave {
            shouldSuspendNextSave = false
            await withCheckedContinuation { continuation in
                suspendedSave = continuation
                saveSuspensionWaiter?.resume()
                saveSuspensionWaiter = nil
            }
        }
        wasSaveCancelled = wasSaveCancelled || Task.isCancelled
        guard !shouldFailSave else {
            throw CustomPlaylistStoreError.invalidCollection
        }
        savedCollections.append(collection)
    }

    func setSaveFailure(_ shouldFail: Bool) {
        shouldFailSave = shouldFail
    }

    func suspendNextSave() {
        shouldSuspendNextSave = true
    }

    func waitForSuspendedSave() async {
        guard suspendedSave == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            saveSuspensionWaiter = continuation
        }
    }

    func resumeSave() {
        suspendedSave?.resume()
        suspendedSave = nil
    }

    func promoteLastSaveToLoadValue() {
        if let last = savedCollections.last {
            loadValue = last
        }
    }
}

private actor CustomPlaylistReconciliationGate {
    let blocksFirstWorker: Bool
    private var firstWorker: CheckedContinuation<Void, Never>?
    private var firstWorkerWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private var running = 0
    private(set) var maximumRunning = 0
    private(set) var ranOnMainThread = false

    init(blocksFirstWorker: Bool = true) {
        self.blocksFirstWorker = blocksFirstWorker
    }

    func reconcile(
        _ collection: CustomPlaylistCollection,
        using index: MediaReferenceResolutionIndex,
        ranOnMainThread: Bool
    ) async -> CustomPlaylistCollection? {
        callCount += 1
        running += 1
        maximumRunning = max(maximumRunning, running)
        self.ranOnMainThread = self.ranOnMainThread || ranOnMainThread
        if callCount == 1, blocksFirstWorker {
            await withCheckedContinuation { continuation in
                firstWorker = continuation
                firstWorkerWaiter?.resume()
                firstWorkerWaiter = nil
            }
        }
        running -= 1
        // Deliberately ignore cancellation: stale result publication must be
        // rejected even when the expensive operation does finish normally.
        var updated = collection
        return updated.reconcile(using: index) ? updated : nil
    }

    func waitForFirstWorker() async {
        guard firstWorker == nil else { return }
        await withCheckedContinuation { firstWorkerWaiter = $0 }
    }

    func releaseFirstWorker() {
        firstWorker?.resume()
        firstWorker = nil
    }
}

private func playlistReconciliationIsMainThread() -> Bool {
    Thread.isMainThread
}
