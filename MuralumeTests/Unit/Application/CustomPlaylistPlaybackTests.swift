import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistPlaybackTests: XCTestCase {
    func testSelectingFilteredResultBuildsQueueFromCompletePlaylist() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Library")
        let first = makeItem(rootURL: rootURL, name: "Cloud", path: "Cloud.mov")
        let selected = makeItem(rootURL: rootURL, name: "Sky", path: "Sky.mov")
        let third = makeItem(rootURL: rootURL, name: "Sea", path: "Sea.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, selected, third]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()

        // The UI only supplies the selected result and playlist identity. The
        // coordinator receives the authoritative, unfiltered collection.
        fixture.coordinator.playCustomPlaylistItem(
            selected,
            playlistID: playlistID,
            playlistItems: [first, selected, third]
        )
        await waitForLoads(fixture.engine, count: 1)

        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.coordinator.queueCount, 3)
        XCTAssertEqual(fixture.coordinator.currentItemID, selected.id)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id, selected.id, third.id]
        )
    }

    func testPlaylistReorderUpdatesPendingItemsWithoutMovingCurrent() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Reorder")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let third = makeItem(rootURL: rootURL, name: "C", path: "C.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second, third]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first, second, third]
        )
        await waitForLoads(fixture.engine, count: 1)

        fixture.coordinator.synchronizeCustomPlaylistQueue(
            playlistID: playlistID,
            playlistItems: [first, third, second]
        )

        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(
            fixture.coordinator.upNextItems.map(\.id),
            [third.id, second.id]
        )
    }

    func testRemovingCurrentPlaylistItemPreservesPausedIntent() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Paused Removal")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.playback.setPlaybackIntent(.paused)

        fixture.coordinator.synchronizeCustomPlaylistQueue(
            playlistID: playlistID,
            playlistItems: [second]
        )
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.playback.isActuallyPlaying)
    }

    func testSelectingPlaylistItemFromQueueKeepsPlaylistMembership() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Queue Selection")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let libraryOnly = makeItem(
            rootURL: rootURL,
            name: "Library Only",
            path: "Library Only.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [first, second, libraryOnly]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)

        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.coordinator.queueCount, 2)
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertFalse(
            fixture.coordinator.makeQueueSnapshot()?.items.contains(
                libraryOnly.id
            ) ?? true
        )
    }

    func testDeletedPlaylistQueueStaysFixedAcrossLibraryRefresh() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Detach")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let libraryOnly = makeItem(
            rootURL: rootURL,
            name: "Library Only",
            path: "Library Only.mov"
        )
        let initialSnapshot = MediaLibrarySnapshot(
            roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
            items: [first, second]
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: initialSnapshot
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)

        fixture.coordinator.detachCustomPlaylistQueue(playlistID: playlistID)
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: initialSnapshot.roots,
                items: [first, second, libraryOnly]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .fixed)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id, second.id]
        )
    }

    func testRestoredPlaylistUsesCurrentOrderAndDoesNotExpandOnRefresh()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Restore")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let third = makeItem(rootURL: rootURL, name: "C", path: "C.mov")
        let libraryOnly = makeItem(
            rootURL: rootURL,
            name: "Library Only",
            path: "Library Only.mov"
        )
        let roots = [
            MediaLibraryRoot(url: rootURL, displayName: "Library")
        ]
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: roots,
                items: [first, second, third]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let savedQueue = PlaybackQueue(
            items: [first.id, second.id, third.id]
        )
        let savedSnapshot = try XCTUnwrap(savedQueue.makeSnapshot())
        let playlistID = CustomPlaylist.ID()

        let result = await fixture.coordinator.restoreQueue(
            from: savedSnapshot,
            playbackCollection: .customPlaylist(playlistID),
            collectionItems: [first, third, second]
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(
            fixture.coordinator.upNextItems.map(\.id),
            [third.id, second.id]
        )

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: roots,
                items: [first, second, third, libraryOnly]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.coordinator.queueCount, 3)
        XCTAssertFalse(
            fixture.coordinator.makeQueueSnapshot()?.items.contains(
                libraryOnly.id
            ) ?? true
        )
    }

    func testPersistedMediaReferenceRestoresRenamedQueueItem() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Persisted Rename")
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([21]),
            fileIdentifier: Data([22])
        )
        let original = makeItem(
            rootURL: rootURL,
            name: "Before",
            path: "Before.mov",
            fileIdentity: identity
        )
        let renamed = makeItem(
            rootURL: rootURL,
            name: "After",
            path: "After.mov",
            fileIdentity: identity
        )
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [renamed]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let savedQueue = PlaybackQueue(items: [original.id])
        let savedSnapshot = try XCTUnwrap(savedQueue.makeSnapshot())

        let result = await fixture.coordinator.restoreQueue(
            from: savedSnapshot,
            queueMediaReferences: [MediaReference(item: original)]
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.coordinator.currentItemID, renamed.id)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [renamed.id]
        )
    }

    func testRestoreMissingPlaylistFallsBackToFixedQueue() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Missing Playlist Restore")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        fixture.coordinator.customPlaylistItemsProvider = { _ in nil }
        let snapshot = try XCTUnwrap(
            PlaybackQueue(items: [first.id, second.id]).makeSnapshot()
        )

        let result = await fixture.coordinator.restoreQueue(
            from: snapshot,
            playbackCollection: .customPlaylist(CustomPlaylist.ID())
        )

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .fixed)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id, second.id]
        )
    }

    func testBridgeReconcilesRenamedReferenceWithoutRecursiveUpdate()
        async throws
    {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Bridge Rename")
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([31]),
            fileIdentifier: Data([32])
        )
        let original = makeItem(
            rootURL: rootURL,
            name: "Before",
            path: "Before.mov",
            fileIdentity: identity
        )
        let renamed = makeItem(
            rootURL: rootURL,
            name: "After",
            path: "After.mov",
            fileIdentity: identity
        )
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "Favorites")
        try collection.add(items: [original], to: playlistID)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [renamed]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlists = CustomPlaylistController(
            store: CustomPlaylistPlaybackStore(collection: collection)
        )
        let bridge = CustomPlaylistPlaybackBridge(
            playlists: playlists,
            library: fixture.coordinator
        )

        await bridge.startAndWait()

        let reference = try XCTUnwrap(
            playlists.collection.playlist(id: playlistID)?
                .entries.first?.media
        )
        XCTAssertEqual(reference.mediaItemID, renamed.id)
        XCTAssertEqual(reference.lastKnownDisplayName, "After")
        XCTAssertEqual(playlists.collectionRevision, 2)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testBridgeImmediatelyUpdatesActiveQueueAfterPlaylistEdit()
        async throws
    {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Bridge Edit")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "Favorites")
        try collection.add(items: [first, second], to: playlistID)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlists = CustomPlaylistController(
            store: CustomPlaylistPlaybackStore(collection: collection)
        )
        let bridge = CustomPlaylistPlaybackBridge(
            playlists: playlists,
            library: fixture.coordinator
        )
        await bridge.startAndWait()
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first, second]
        )
        await waitForLoads(fixture.engine, count: 1)
        let secondEntryID = try XCTUnwrap(
            playlists.collection.playlist(id: playlistID)?
                .entries.last?.id
        )

        try playlists.removeEntry(secondEntryID, from: playlistID)

        XCTAssertEqual(fixture.coordinator.queueCount, 1)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id]
        )
        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }
}

private actor CustomPlaylistPlaybackStore: CustomPlaylistStoring {
    private let collection: CustomPlaylistCollection

    init(collection: CustomPlaylistCollection) {
        self.collection = collection
    }

    func load() -> CustomPlaylistCollection {
        collection
    }

    func save(_: CustomPlaylistCollection) {}
}
