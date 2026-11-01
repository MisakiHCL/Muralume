import Combine
import Darwin
import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistSynchronizationTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/Playlist Synchronization")

    func testRenamesAndUnrelatedEntryEditsNeverSynchronizeActiveQueue()
        async throws {
        let first = item("A")
        let second = item("B")
        var collection = CustomPlaylistCollection.empty
        let activeID = try collection.createPlaylist(named: "Active")
        let otherID = try collection.createPlaylist(named: "Other")
        try collection.add(items: [first, second], to: activeID)
        try collection.add(items: [second], to: otherID)
        let (fixture, playlists, bridge) = await start(
            items: [first, second], collection: collection
        )
        fixture.coordinator.playCustomPlaylistItem(
            first, playlistID: activeID, playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)
        let snapshot = fixture.coordinator.makeQueueSnapshot()
        let queueRevision = fixture.coordinator.queueRevision
        let synchronizationCount = bridge.activeQueueSynchronizationCount
        let resolutionCount = playlists.resolvedItemsRecomputationCount

        // This includes the first edit after playback starts: no previous
        // bridge synchronization is required for the unchanged-media shortcut.
        try playlists.renamePlaylist(id: otherID, to: "Other Renamed")
        try playlists.renamePlaylist(id: activeID, to: "Active Renamed")
        try playlists.add(items: [first], to: otherID)
        let otherEntry = try XCTUnwrap(
            playlists.collection.playlist(id: otherID)?.entries.first?.id
        )
        try playlists.removeEntry(otherEntry, from: otherID)
        await playlists.waitForLibraryReconciliation()

        XCTAssertEqual(bridge.activeQueueSynchronizationCount, synchronizationCount)
        XCTAssertEqual(playlists.resolvedItemsRecomputationCount, resolutionCount)
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), snapshot)
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testMoveImmediatelyUpdatesPendingOrderAndPreservesCurrentAndHistory()
        async throws {
        let items = [item("A"), item("B"), item("C"), item("D")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: items, to: id)
        let (fixture, playlists, bridge) = await start(items: items, collection: collection)
        let resolved = playlists.resolvedItems(
            in: id, using: fixture.coordinator.items,
            itemsRevision: fixture.coordinator.itemsRevision
        )
        fixture.coordinator.playCustomPlaylistItem(
            items[0], playlistID: id, playlistItems: resolved
        )
        await waitForLoads(fixture.engine, count: 1)
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        let before = try XCTUnwrap(fixture.coordinator.makeQueueSnapshot())
        let entries = try XCTUnwrap(playlists.collection.playlist(id: id)?.entries)
        let resolutionCount = playlists.resolvedItemsRecomputationCount

        try playlists.moveEntry(entries[3].id, before: entries[2].id, in: id)

        let after = try XCTUnwrap(fixture.coordinator.makeQueueSnapshot())
        XCTAssertEqual(after.items, [items[0].id, items[1].id, items[3].id, items[2].id])
        XCTAssertEqual(after.currentItem, items[1].id)
        XCTAssertEqual(after.history, before.history)
        XCTAssertEqual(after.forwardHistory, before.forwardHistory)
        XCTAssertEqual(fixture.coordinator.upNextItems.map(\.id), [items[3].id, items[2].id])
        XCTAssertEqual(playlists.resolvedItemsRecomputationCount, resolutionCount)
        XCTAssertEqual(fixture.engine.loadedSources.count, 2)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testLibraryMetadataRenameAndAvailabilityInvalidateActiveQueueCache()
        async throws {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([71]), fileIdentifier: Data([72])
        )
        let first = item("A", identity: identity)
        let second = item("B")
        let renamed = item("Renamed", identity: identity)
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: [first, second], to: id)
        let (fixture, playlists, bridge) = await start(
            items: [first, second], collection: collection
        )
        fixture.coordinator.playCustomPlaylistItem(
            first, playlistID: id, playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)

        fixture.scanner.enqueueSnapshot(snapshot(items: [renamed]))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        await playlists.waitForLibraryReconciliation()
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [renamed.id])
        XCTAssertEqual(fixture.coordinator.currentItemID, renamed.id)
        XCTAssertEqual(fixture.coordinator.currentItem?.displayName, "Renamed")

        let renamedMetadata = item("Renamed", size: 321, identity: identity)
        fixture.scanner.enqueueSnapshot(snapshot(items: [renamedMetadata, second]))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        await playlists.waitForLibraryReconciliation()
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [renamedMetadata.id, second.id]
        )
        XCTAssertEqual(fixture.coordinator.currentItem?.fileSize, 321)
        XCTAssertEqual(fixture.coordinator.upNextItems.map(\.id), [second.id])
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testIndependentAccessFollowsAuthorizedLibraryRenameAndReusesSortContent() async throws {
        try await verifyIndependentLibraryMove(to: rootURL)
    }

    func testIndependentAccessAdoptsDestinationGrantForLibraryRootMove() async throws {
        try await verifyIndependentLibraryMove(to: URL(fileURLWithPath: "/tmp/Playlist Destination"))
    }

    func testLegacyV1BackfillUpdatesRenamedReferenceBeforeIndependentResolution() async throws {
        try await verifyLegacyLibraryMove(to: rootURL)
    }

    func testLegacyV1BackfillUpdatesMovedRootAndPersistsDestinationGrant() async throws {
        try await verifyLegacyLibraryMove(to: URL(fileURLWithPath: "/tmp/Legacy Playlist Destination"))
    }

    func testIndependentIdentityMoveWithoutDestinationGrantKeepsOriginalReference() async throws {
        let identity = MediaFileIdentity(volumeIdentifier: Data([81]), fileIdentifier: Data([82]))
        let first = item("A", identity: identity)
        let moved = makeItem(
            rootURL: URL(fileURLWithPath: "/tmp/Unowned Playlist Destination"),
            name: "B", path: "B.mov", fileIdentity: identity
        )
        let access = synchronizationGrant(for: rootURL)
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Protected")
        try collection.add(items: [first], to: id, grantsByItemID: [first.id: access])
        let state = SynchronizationMediaFiles(grants: [access], items: [first])
        let controller = CustomPlaylistController(
            store: SynchronizationPlaylistStore(collection),
            grantCapture: { $0.id.rootPath == access.sourcePath ? access : nil },
            resolver: SecurityScopedCustomPlaylistMediaAccess(operations: state.operations)
        )
        await controller.startAndWait()
        state.replaceItems([moved])

        controller.updateAvailableItems(
            [moved], itemsRevision: 1, contentRevision: 1,
            resolutionIndex: MediaReferenceResolutionIndex(items: [moved])
        )
        await controller.waitForLibraryReconciliation()

        XCTAssertEqual(controller.collection, collection)
        XCTAssertTrue(controller.resolvedItems(in: id).isEmpty)
        let entry = try XCTUnwrap(controller.collection.allEntries.first)
        XCTAssertEqual(controller.issue(for: entry), .fileMissing)
        await controller.shutdown()
    }

    func testIndependentLibraryReconciliationKeepsExactFirstIdentityConflictProtection() async throws {
        let firstIdentity = MediaFileIdentity(volumeIdentifier: Data([83]), fileIdentifier: Data([84]))
        let secondIdentity = MediaFileIdentity(volumeIdentifier: Data([83]), fileIdentifier: Data([85]))
        let original = item("A", identity: firstIdentity)
        let exact = item("B", identity: secondIdentity)
        let replacement = item("B", identity: firstIdentity)
        let access = synchronizationGrant(for: rootURL)
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Exact First")
        try collection.add(
            items: [original, exact], to: id,
            grantsByItemID: [original.id: access, exact.id: access]
        )
        let state = SynchronizationMediaFiles(grants: [access], items: [original, exact])
        let controller = CustomPlaylistController(
            store: SynchronizationPlaylistStore(collection), grantCapture: { _ in access },
            resolver: SecurityScopedCustomPlaylistMediaAccess(operations: state.operations)
        )
        await controller.startAndWait()
        state.replaceItems([replacement])

        controller.updateAvailableItems(
            [replacement], itemsRevision: 1, contentRevision: 1,
            resolutionIndex: MediaReferenceResolutionIndex(items: [replacement])
        )
        await controller.waitForLibraryReconciliation()

        XCTAssertTrue(controller.collection.isValid)
        XCTAssertEqual(controller.collection.allEntries.map(\.media.mediaItemID), [original.id, exact.id])
        XCTAssertEqual(controller.collection.allEntries.map(\.media.fileIdentity), [firstIdentity, secondIdentity])
        XCTAssertEqual(controller.resolvedItems(in: id).map(\.id), [exact.id])
        await controller.shutdown()
    }

    func testEditsDuringScanApplyLatestOrderWhenLibraryBecomesReady()
        async throws {
        let items = [item("A"), item("B"), item("C")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: items, to: id)
        let (fixture, playlists, bridge) = await start(items: items, collection: collection)
        fixture.coordinator.playCustomPlaylistItem(
            items[0], playlistID: id, playlistItems: items
        )
        await waitForLoads(fixture.engine, count: 1)
        fixture.scanner.blockNextScan()
        fixture.coordinator.refresh()
        await waitUntil { fixture.scanner.didBeginBlockedScan }
        let entries = try XCTUnwrap(playlists.collection.playlist(id: id)?.entries)

        try playlists.moveEntry(entries[2].id, before: entries[1].id, in: id)
        try playlists.renamePlaylist(id: id, to: "Renamed During Scan")
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, items.map(\.id))
        fixture.scanner.finishBlockedScan()
        await waitForScan(fixture.coordinator)
        await playlists.waitForLibraryReconciliation()

        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [items[0].id, items[2].id, items[1].id]
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, items[0].id)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testResolutionCacheHandlesIncomingAndCurrentPublishedSnapshots()
        async throws {
        let items = [item("A"), item("B")]
        let controller = CustomPlaylistController(store: SynchronizationPlaylistStore(.empty))
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Active")
        try controller.add(items: items, to: id)
        let originalCollection = controller.collection
        _ = controller.resolvedItems(in: id, using: items, itemsRevision: 1)
        let entryIDs = try XCTUnwrap(controller.collection.playlist(id: id)?.entries.map(\.id))
        var observedIncoming = false
        let observation = controller.collectionPublisher.dropFirst().sink { incoming in
            observedIncoming = true
            XCTAssertEqual(controller.collection, originalCollection)
            XCTAssertEqual(controller.resolvedItems(in: id, using: items, itemsRevision: 1), items)
            XCTAssertEqual(
                controller.resolvedItems(in: id, collection: incoming, using: items, itemsRevision: 1),
                [items[1], items[0]]
            )
            // A will-change observer may repopulate the cache with the old
            // current value after another observer reads the incoming value.
            XCTAssertEqual(controller.resolvedItems(in: id, using: items, itemsRevision: 1), items)
        }

        try controller.moveEntry(entryIDs[1], before: entryIDs[0], in: id)

        XCTAssertTrue(observedIncoming)
        XCTAssertEqual(
            controller.resolvedItems(in: id, using: items, itemsRevision: 1),
            [items[1], items[0]]
        )
        XCTAssertEqual(controller.resolvedItemsRecomputationCount, 1)
        observation.cancel()
        await controller.shutdown()
    }

    func testResolutionCacheDoesNotReuseCompetingIdentityAssignments()
        async throws {
        let firstIdentity = MediaFileIdentity(
            volumeIdentifier: Data([73]), fileIdentifier: Data([74])
        )
        let secondIdentity = MediaFileIdentity(
            volumeIdentifier: Data([73]), fileIdentifier: Data([75])
        )
        let original = item("A", identity: firstIdentity)
        let exact = item("B", identity: secondIdentity)
        let renamedOverExact = item("B", identity: firstIdentity)
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: [original, exact], to: id)
        let controller = CustomPlaylistController(store: SynchronizationPlaylistStore(collection))
        await controller.startAndWait()
        let entries = try XCTUnwrap(controller.collection.playlist(id: id)?.entries)
        XCTAssertEqual(
            controller.resolvedItems(in: id, using: [renamedOverExact], itemsRevision: 1),
            [renamedOverExact]
        )
        try controller.moveEntry(entries[1].id, before: entries[0].id, in: id)
        XCTAssertEqual(
            controller.resolvedItems(in: id, using: [renamedOverExact], itemsRevision: 1),
            [renamedOverExact]
        )
        XCTAssertEqual(controller.resolvedItemsRecomputationCount, 2)
        await controller.shutdown()
    }

    func testResolutionCacheInvalidatesForContentAndReleasesAtEmptyAndShutdown()
        async throws {
        let first = item("A")
        let metadata = item("A", size: 123)
        let controller = CustomPlaylistController(store: SynchronizationPlaylistStore(.empty))
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Active")
        try controller.add(items: [first], to: id)
        controller.updateAvailableItems([first], itemsRevision: 1, contentRevision: 1)
        await controller.waitForLibraryReconciliation()
        XCTAssertEqual(controller.resolvedItems(in: id, using: [first], itemsRevision: 1), [first])
        controller.updateAvailableItems([metadata], itemsRevision: 2, contentRevision: 2)
        XCTAssertFalse(controller.hasCachedResolvedItems)
        XCTAssertEqual(controller.resolvedItems(in: id, using: [metadata], itemsRevision: 2), [metadata])
        let entryID = try XCTUnwrap(controller.collection.playlist(id: id)?.entries.first?.id)
        try controller.removeEntry(entryID, from: id)
        XCTAssertFalse(controller.hasCachedResolvedItems)
        try controller.add(items: [metadata], to: id)
        _ = controller.resolvedItems(in: id, using: [metadata], itemsRevision: 2)
        XCTAssertTrue(controller.hasCachedResolvedItems)
        await controller.shutdown()
        XCTAssertFalse(controller.hasCachedResolvedItems)
    }

    func testRevisionlessResolutionDoesNotReuseOrRetainOldAvailability()
        async throws {
        let first = item("A")
        let controller = CustomPlaylistController(store: SynchronizationPlaylistStore(.empty))
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Active")
        try controller.add(items: [first], to: id)
        XCTAssertEqual(controller.resolvedItems(in: id, using: [first], itemsRevision: 1), [first])
        XCTAssertTrue(controller.resolvedItems(in: id, using: []).isEmpty)
        XCTAssertFalse(controller.hasCachedResolvedItems)
        XCTAssertEqual(controller.resolvedItems(in: id, using: [first]), [first])
        XCTAssertFalse(controller.hasCachedResolvedItems)
        await controller.shutdown()
    }

    func testLibrarySortRevisionAliasesResolvedMediaContent() async throws {
        let items = [item("A"), item("B")]
        let controller = CustomPlaylistController(store: SynchronizationPlaylistStore(.empty))
        await controller.startAndWait()
        let id = try controller.createPlaylist(named: "Active")
        try controller.add(items: items, to: id)
        let index = MediaReferenceResolutionIndex(items: items)
        controller.updateAvailableItems(
            items, itemsRevision: 1, contentRevision: 1, resolutionIndex: index
        )
        await controller.waitForLibraryReconciliation()
        XCTAssertEqual(controller.resolvedItems(in: id, using: items, itemsRevision: 1), items)
        controller.updateAvailableItems(
            Array(items.reversed()), itemsRevision: 2, contentRevision: 1, resolutionIndex: index
        )

        XCTAssertEqual(
            controller.resolvedItems(in: id, using: Array(items.reversed()), itemsRevision: 2),
            items
        )
        XCTAssertEqual(controller.resolvedItemsRecomputationCount, 1)
        await controller.shutdown()
    }

    func testMoveForwardBackwardAndToEndPreservesNoOpTimestamp() throws {
        let items = [item("A"), item("B"), item("C")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: items, to: id)
        let entries = try XCTUnwrap(collection.playlist(id: id)?.entries)
        let changedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try collection.moveEntry(entries[0].id, before: entries[2].id, in: id, now: changedAt)
        XCTAssertEqual(collection.playlist(id: id)?.entries.map(\.id), [entries[1].id, entries[0].id, entries[2].id])
        try collection.moveEntry(entries[0].id, before: entries[2].id, in: id)
        XCTAssertEqual(collection.playlist(id: id)?.updatedAt, changedAt)
        try collection.moveEntry(entries[2].id, before: nil, in: id)
        XCTAssertEqual(collection.playlist(id: id)?.updatedAt, changedAt)
        try collection.moveEntry(entries[0].id, before: nil, in: id)
        XCTAssertEqual(collection.playlist(id: id)?.entries.map(\.id), [entries[1].id, entries[2].id, entries[0].id])
        try collection.moveEntry(entries[0].id, before: entries[1].id, in: id)
        XCTAssertEqual(collection.playlist(id: id)?.entries.map(\.id), entries.map(\.id))
    }

    func testBatchRemovalPreservesUnselectedEntriesAndIgnoresStaleSelection()
        throws {
        let items = [item("A"), item("B"), item("Offline"), item("D")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Favorites")
        try collection.add(items: items, to: id)
        let entries = try XCTUnwrap(collection.playlist(id: id)?.entries)
        let changedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            try collection.removeEntries(
                [entries[0].id, entries[2].id, CustomPlaylistEntry.ID()],
                from: id,
                now: changedAt
            ),
            2
        )
        XCTAssertEqual(
            collection.playlist(id: id)?.entries,
            [entries[1], entries[3]]
        )
        XCTAssertEqual(collection.playlist(id: id)?.updatedAt, changedAt)
        XCTAssertEqual(
            try collection.removeEntries([entries[0].id], from: id),
            0
        )
        XCTAssertEqual(collection.playlist(id: id)?.updatedAt, changedAt)
        XCTAssertThrowsError(
            try collection.removeEntries([], from: CustomPlaylist.ID())
        ) {
            XCTAssertEqual($0 as? CustomPlaylistMutationError, .playlistNotFound)
        }
    }

    func testBatchAddIsAtomicAtCapacityAndAlreadyAddedMediaIsANoOp()
        throws {
        let items = (0..<CustomPlaylistPolicy.maximumEntriesPerPlaylist)
            .map { item("Video \($0)") }
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Full")
        try collection.add(items: Array(items.dropLast()), to: id)
        let before = collection

        XCTAssertThrowsError(
            try collection.add(items: [items.last!, item("Extra")], to: id)
        ) {
            XCTAssertEqual($0 as? CustomPlaylistMutationError, .entryLimitReached)
        }
        XCTAssertEqual(collection, before)
        XCTAssertEqual(try collection.add(items: [items.last!], to: id), 1)
        let full = collection
        XCTAssertEqual(try collection.add(items: items, to: id), 0)
        XCTAssertEqual(collection, full)
    }

    func testBatchMutationsPublishAndPersistOneSnapshotEach() async throws {
        let items = [item("A"), item("B"), item("C")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Favorites")
        try collection.add(items: [items[0]], to: id)
        let addStore = SynchronizationPlaylistStore(collection)
        let adding = CustomPlaylistController(store: addStore)
        await adding.startAndWait()
        var addPublications = 0
        let addObservation = adding.collectionPublisher.dropFirst().sink { _ in
            addPublications += 1
        }

        XCTAssertEqual(try adding.add(items: [items[2], items[1], items[2]], to: id), 2)
        XCTAssertEqual(try adding.add(items: items, to: id), 0)
        XCTAssertEqual(addPublications, 1)
        await adding.shutdown()
        let addSaves = await addStore.savedCollections
        XCTAssertEqual(addSaves.count, 1)
        XCTAssertEqual(
            addSaves.first?.playlist(id: id)?.entries.map(\.media.mediaItemID),
            [items[0].id, items[2].id, items[1].id]
        )
        addObservation.cancel()

        let added = try XCTUnwrap(addSaves.first)
        let entries = try XCTUnwrap(added.playlist(id: id)?.entries)
        let removeStore = SynchronizationPlaylistStore(added)
        let removing = CustomPlaylistController(store: removeStore)
        await removing.startAndWait()
        var removePublications = 0
        let removeObservation = removing.collectionPublisher.dropFirst().sink { _ in
            removePublications += 1
        }
        XCTAssertEqual(
            try removing.removeEntries([entries[0].id, entries[2].id], from: id),
            2
        )
        XCTAssertEqual(try removing.removeEntries([], from: id), 0)
        XCTAssertEqual(removePublications, 1)
        await removing.shutdown()
        let removeSaves = await removeStore.savedCollections
        XCTAssertEqual(removeSaves.count, 1)
        XCTAssertEqual(removeSaves.first?.playlist(id: id)?.entries, [entries[1]])
        removeObservation.cancel()
    }

    func testBatchEditsSynchronizeActiveQueueOnceAndPreservePlayback()
        async throws {
        let items = [item("A"), item("B"), item("C"), item("D"), item("E"), item("F")]
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Active")
        try collection.add(items: Array(items.prefix(4)), to: id)
        let (fixture, playlists, bridge) = await start(items: items, collection: collection)
        fixture.coordinator.playCustomPlaylistItem(
            items[0], playlistID: id, playlistItems: Array(items.prefix(4))
        )
        await waitForLoads(fixture.engine, count: 1)
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        let before = try XCTUnwrap(fixture.coordinator.makeQueueSnapshot())
        let synchronizationCount = bridge.activeQueueSynchronizationCount

        try playlists.add(items: [items[4], items[5], items[4]], to: id)
        XCTAssertEqual(bridge.activeQueueSynchronizationCount, synchronizationCount + 1)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, items.map(\.id))
        let entries = try XCTUnwrap(playlists.collection.playlist(id: id)?.entries)

        try playlists.removeEntries([entries[2].id, entries[4].id], from: id)

        let after = try XCTUnwrap(fixture.coordinator.makeQueueSnapshot())
        XCTAssertEqual(bridge.activeQueueSynchronizationCount, synchronizationCount + 2)
        XCTAssertEqual(after.items, [items[0].id, items[1].id, items[3].id, items[5].id])
        XCTAssertEqual(after.currentItem, items[1].id)
        XCTAssertEqual(after.history, before.history)
        XCTAssertEqual(fixture.coordinator.upNextItems.map(\.id), [items[3].id, items[5].id])
        XCTAssertEqual(fixture.engine.loadedSources.count, 2)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testCreateWithItemsPublishesAndSavesOnlyThePopulatedPlaylist()
        async throws {
        let items = [item("A"), item("B")]
        let store = SynchronizationPlaylistStore(.empty)
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()
        var publications: [CustomPlaylistCollection] = []
        let observation = controller.collectionPublisher.dropFirst().sink {
            publications.append($0)
        }

        let id = try controller.createPlaylist(
            named: "Selected Videos", items: [items[1], items[0], items[1]]
        )

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(
            publications.first?.playlist(id: id)?.entries.map(\.media.mediaItemID),
            [items[1].id, items[0].id]
        )
        await controller.shutdown()
        let saves = await store.savedCollections
        XCTAssertEqual(saves, publications)
        observation.cancel()
    }

    func testCreateWithItemsFailureNeverLeavesAnEmptyPlaylistOrSave()
        async throws {
        var initial = CustomPlaylistCollection.empty
        try initial.createPlaylist(named: "Existing")
        let store = SynchronizationPlaylistStore(initial)
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()
        let revision = controller.collectionRevision
        let tooManyItems = (0...CustomPlaylistPolicy.maximumEntriesPerPlaylist)
            .map { item("Video \($0)") }
        var publications = 0
        let observation = controller.collectionPublisher.dropFirst().sink { _ in
            publications += 1
        }

        for (name, items, expected) in [
            ("Too Many", tooManyItems, CustomPlaylistMutationError.entryLimitReached),
            ("Existing", [item("A")], .duplicateName),
            ("   ", [item("A")], .invalidName)
        ] {
            XCTAssertThrowsError(try controller.createPlaylist(named: name, items: items)) {
                XCTAssertEqual($0 as? CustomPlaylistMutationError, expected)
            }
        }

        XCTAssertEqual(controller.collection, initial)
        XCTAssertEqual(controller.collectionRevision, revision)
        XCTAssertEqual(publications, 0)
        await controller.shutdown()
        let saves = await store.savedCollections
        XCTAssertTrue(saves.isEmpty)
        observation.cancel()
    }

    func testCreationInputKeepsOriginalOrderAndRejectsReplacementOrRemoval()
        throws {
        let first = item("A")
        let second = item("B")
        let input = CustomPlaylistCreationInput(items: [second, first])
        let current = [first.id: first, second.id: second]
        XCTAssertEqual(try input.validatedItems(using: current), [second, first])
        XCTAssertThrowsError(try input.validatedItems(using: [first.id: first])) {
            XCTAssertEqual($0 as? CustomPlaylistCreationInputError, .selectionChanged)
        }
        let replaced = item("B", size: 123)
        XCTAssertThrowsError(
            try input.validatedItems(using: [first.id: first, replaced.id: replaced])
        ) {
            XCTAssertEqual($0 as? CustomPlaylistCreationInputError, .selectionChanged)
        }
        XCTAssertTrue(
            try CustomPlaylistCreationInput(items: []).validatedItems(using: [:]).isEmpty
        )
    }

    private func item(
        _ name: String,
        size: Int64 = 1,
        identity: MediaFileIdentity? = nil
    ) -> LibraryMediaItem {
        makeItem(
            rootURL: rootURL, name: name, path: "\(name).mov",
            fileSize: size, fileIdentity: identity
        )
    }

    private func synchronizationGrant(for root: URL) -> CustomPlaylistMediaGrant {
        CustomPlaylistMediaGrant(sourcePath: root.path, kind: .folder, bookmark: Data(root.path.utf8))
    }

    private func verifyIndependentLibraryMove(to destination: URL) async throws {
        let identity = MediaFileIdentity(volumeIdentifier: Data([86]), fileIdentifier: Data([87]))
        let first = item("A", identity: identity)
        let tail = item("Tail")
        let moved = makeItem(rootURL: destination, name: "B", path: "B.mov", fileIdentity: identity)
        let originalGrant = synchronizationGrant(for: rootURL)
        let destinationGrant = destination == rootURL ? originalGrant : synchronizationGrant(for: destination)
        let grantsByPath = Dictionary([originalGrant, destinationGrant].map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Independent Rename")
        try collection.add(
            items: [first, tail], to: id,
            grantsByItemID: [first.id: originalGrant, tail.id: originalGrant]
        )
        let entryIDs = collection.allEntries.map(\.id)
        let state = SynchronizationMediaFiles(grants: Array(grantsByPath.values), items: [first, tail])
        let store = SynchronizationPlaylistStore(collection)
        var captures = 0
        let controller = CustomPlaylistController(
            store: store,
            grantCapture: { item in captures += 1; return grantsByPath[item.id.rootPath] },
            resolver: SecurityScopedCustomPlaylistMediaAccess(operations: state.operations)
        )
        await controller.startAndWait()
        controller.updateAvailableItems(
            [first, tail], itemsRevision: 1, contentRevision: 1,
            resolutionIndex: MediaReferenceResolutionIndex(items: [first, tail])
        )
        await controller.waitForLibraryReconciliation()
        state.replaceItems([moved, tail])
        let index = MediaReferenceResolutionIndex(items: [moved, tail])

        controller.updateAvailableItems([moved, tail], itemsRevision: 2, contentRevision: 2, resolutionIndex: index)
        await controller.waitForLibraryReconciliation()

        XCTAssertEqual(controller.collection.allEntries.map(\.id), entryIDs)
        XCTAssertEqual(controller.collection.allEntries.map(\.media.mediaItemID), [moved.id, tail.id])
        XCTAssertEqual(controller.collection.allEntries.first?.accessGrantID, destinationGrant.id)
        XCTAssertEqual(controller.resolvedItems(in: id).map(\.url), [moved.url, tail.url])
        XCTAssertTrue(controller.resolvedItems(in: id).allSatisfy { $0.accessLease != nil })
        let collectionRevision = controller.collectionRevision
        let captureCount = captures
        controller.updateAvailableItems([tail, moved], itemsRevision: 3, contentRevision: 2, resolutionIndex: index)
        await controller.waitForLibraryReconciliation()
        XCTAssertEqual(controller.collectionRevision, collectionRevision)
        XCTAssertEqual(captures, captureCount, "A pure library reorder must not repeat reconciliation or grant capture")
        let persisted = await controller.flushPersistence()
        XCTAssertTrue(persisted)
        let saves = await store.savedCollections
        XCTAssertEqual(saves.last?.allEntries.map(\.media.mediaItemID), [moved.id, tail.id])
        await controller.shutdown()
    }

    private func verifyLegacyLibraryMove(to destination: URL) async throws {
        let identity = MediaFileIdentity(volumeIdentifier: Data([88]), fileIdentifier: Data([89]))
        let first = item("A", identity: identity)
        let moved = makeItem(rootURL: destination, name: "B", path: "B.mov", fileIdentity: identity)
        let access = synchronizationGrant(for: destination)
        var initial = CustomPlaylistCollection.empty
        let id = try initial.createPlaylist(named: "Legacy Rename")
        try initial.add(items: [first], to: id)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        payload["schemaVersion"] = 1
        payload.removeValue(forKey: "accessGrants")
        let legacy = try JSONDecoder().decode(CustomPlaylistCollection.self, from: JSONSerialization.data(withJSONObject: payload))
        let entryID = try XCTUnwrap(legacy.allEntries.first?.id)
        let state = SynchronizationMediaFiles(grants: [access], items: [moved])
        let store = SynchronizationPlaylistStore(legacy)
        let capture: CustomPlaylistController.SourceGrantCapture = {
            $0.standardizedPath == access.sourcePath ? access : nil
        }
        let controller = CustomPlaylistController(
            store: store, sourceGrantCapture: capture,
            resolver: SecurityScopedCustomPlaylistMediaAccess(operations: state.operations)
        )
        await controller.startAndWait()

        controller.updateAvailableItems(
            [moved], itemsRevision: 1, contentRevision: 1,
            resolutionIndex: MediaReferenceResolutionIndex(items: [moved])
        )
        await controller.waitForLibraryReconciliation()

        XCTAssertEqual(controller.collection.allEntries.first?.id, entryID)
        XCTAssertEqual(controller.collection.allEntries.first?.media.mediaItemID, moved.id)
        XCTAssertEqual(controller.collection.allEntries.first?.accessGrantID, access.id)
        XCTAssertEqual(controller.collection.accessGrants, [access])
        XCTAssertEqual(controller.resolvedItems(in: id).map(\.url), [moved.url])
        let persisted = await controller.flushPersistence()
        XCTAssertTrue(persisted)
        let saves = await store.savedCollections
        let saved = try XCTUnwrap(saves.last)
        let restored = try JSONDecoder().decode(CustomPlaylistCollection.self, from: JSONEncoder().encode(saved))
        await controller.shutdown()
        let cold = CustomPlaylistController(
            store: SynchronizationPlaylistStore(restored),
            resolver: SecurityScopedCustomPlaylistMediaAccess(operations: state.operations)
        )
        await cold.startAndWait()
        XCTAssertEqual(cold.collection.allEntries.first?.id, entryID)
        XCTAssertEqual(cold.resolvedItems(in: id).map(\.url), [moved.url])
        await cold.shutdown()
    }

    private func snapshot(items: [LibraryMediaItem]) -> MediaLibrarySnapshot {
        MediaLibrarySnapshot(
            roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
            items: items
        )
    }

    private func start(
        items: [LibraryMediaItem],
        collection: CustomPlaylistCollection
    ) async -> (Fixture, CustomPlaylistController, CustomPlaylistPlaybackBridge) {
        let fixture = makeFixture(selectedURLs: [], snapshot: snapshot(items: items))
        fixture.session.restoredURLs = [rootURL]
        let generation = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: generation)
        let playlists = CustomPlaylistController(store: SynchronizationPlaylistStore(collection))
        let bridge = CustomPlaylistPlaybackBridge(playlists: playlists, library: fixture.coordinator)
        await bridge.startAndWait()
        return (fixture, playlists, bridge)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for blocked playlist scan")
    }
}

/// Models only explicitly supplied synthetic roots/files; no native bookmarks
/// or user media are read by the production resolver in these regressions.
private final class SynchronizationMediaFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let rootsByBookmark: [Data: URL]
    private var files: [String: LibraryMediaItem]

    init(grants: [CustomPlaylistMediaGrant], items: [LibraryMediaItem]) {
        rootsByBookmark = Dictionary(grants.map { ($0.bookmark, URL(fileURLWithPath: $0.sourcePath)) }, uniquingKeysWith: { first, _ in first })
        files = Dictionary(items.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func replaceItems(_ items: [LibraryMediaItem]) {
        lock.withLock { files = Dictionary(items.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    var operations: CustomPlaylistBookmarkOperations {
        CustomPlaylistBookmarkOperations(
            resolve: { [self] bookmark in
                guard let url = rootsByBookmark[bookmark] else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                return .init(url: url)
            },
            startAccess: { _ in true }, stopAccess: { _ in },
            makeBookmark: { [self] url in
                guard let bookmark = rootsByBookmark.first(where: { $0.value.path == url.path })?.key else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return bookmark
            },
            metadata: { [self] url in
                if rootsByBookmark.values.contains(where: { $0.path == url.path }) {
                    return .init(isDirectory: true, isRegularFile: false)
                }
                guard let item = lock.withLock({ files[url.path] }) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                }
                return .init(creationDate: item.creationDate, modificationDate: item.modificationDate,
                             fileSize: item.fileSize, fileIdentity: item.fileIdentity)
            },
            canonicalURL: { $0.standardizedFileURL }
        )
    }
}

private actor SynchronizationPlaylistStore: CustomPlaylistStoring {
    private let collection: CustomPlaylistCollection
    private(set) var savedCollections: [CustomPlaylistCollection] = []

    init(_ collection: CustomPlaylistCollection) {
        self.collection = collection
    }

    func load() -> CustomPlaylistCollection { collection }

    func save(_ collection: CustomPlaylistCollection) {
        savedCollections.append(collection)
    }
}
