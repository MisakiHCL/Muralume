import Combine
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

private actor SynchronizationPlaylistStore: CustomPlaylistStoring {
    private let collection: CustomPlaylistCollection

    init(_ collection: CustomPlaylistCollection) {
        self.collection = collection
    }

    func load() -> CustomPlaylistCollection { collection }

    func save(_: CustomPlaylistCollection) {}
}
