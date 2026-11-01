import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistPlaybackTests: XCTestCase {
    func testEmptyLibraryRequiresIndependentAccessToPlayPlaylistItem() async {
        let item = makeItem(
            rootURL: URL(fileURLWithPath: "/tmp/Independent Playlist"),
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: .empty)
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()

        fixture.coordinator.playCustomPlaylistItem(
            item,
            playlistID: playlistID,
            playlistItems: [item]
        )

        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertTrue(fixture.engine.loadedSources.isEmpty)

        let lease = MediaSourceAccessLease(retaining: PlaylistAccessOwner())
        let authorizedItem = itemWithAccessLease(item, lease: lease)
        fixture.coordinator.playCustomPlaylistItem(
            authorizedItem,
            playlistID: playlistID,
            playlistItems: [authorizedItem]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.engine.loadedSources.last?.accessLease, lease)
        await fixture.coordinator.shutdown()
    }

    func testRemovingLastLibrarySourcePreservesOwnedPlaylistAndPausedIntent()
        async
    {
        let rootURL = URL(fileURLWithPath: "/tmp/Retained Playlist")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let lease = MediaSourceAccessLease(retaining: PlaylistAccessOwner())
        let authorizedFirst = itemWithAccessLease(first, lease: lease)
        let authorizedSecond = itemWithAccessLease(second, lease: lease)
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        var preparedRootIDs: [MediaLibraryRoot.ID] = []
        fixture.coordinator.prepareForPlaylistSourceRemoval = { source in
            preparedRootIDs.append(source.id)
            return true
        }
        fixture.coordinator.retainedPlaylistItemsProvider = {
            [authorizedFirst, authorizedSecond]
        }
        var revokedItemIDs: Set<LibraryMediaItem.ID> = []
        fixture.coordinator.mediaItemsWillBeRemovedHandler = { ids in
            revokedItemIDs.formUnion(ids)
        }
        fixture.coordinator.playCustomPlaylistItem(
            authorizedFirst,
            playlistID: playlistID,
            playlistItems: [authorizedFirst, second]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.playback.setPlaybackIntent(.paused)

        await fixture.coordinator.removeRoot(root)

        XCTAssertEqual(preparedRootIDs, [root.id])
        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertEqual(fixture.session.removedURLs, [rootURL])
        XCTAssertTrue(revokedItemIDs.isEmpty)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot()?.items,
            [first.id, second.id]
        )
        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.playback.readiness, .ready)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.playback.isActuallyPlaying)
        XCTAssertEqual(fixture.engine.loadedSources.last?.accessLease, lease)

        // The pending row originally came from the library. Its replacement
        // must use the independent grant after that library source is gone.
        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.engine.loadedSources.last?.url, second.url)
        XCTAssertEqual(fixture.engine.loadedSources.last?.accessLease, lease)
        await fixture.coordinator.shutdown()
    }

    func testBorrowedPlaylistAccessHandoverUsesImmediateTransitionAfterDetach()
        async
    {
        let firstRootURL = URL(fileURLWithPath: "/tmp/Borrowed Playlist")
        let secondRootURL = URL(fileURLWithPath: "/tmp/Remaining Library")
        let firstRoot = MediaLibraryRoot(url: firstRootURL, displayName: "A")
        let secondRoot = MediaLibraryRoot(url: secondRootURL, displayName: "B")
        let first = makeItem(rootURL: firstRootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: secondRootURL, name: "B", path: "B.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [firstRoot, secondRoot],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [firstRootURL, secondRootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.playback.setQueueCrossfadeEnabled(true)
        fixture.coordinator.playCustomPlaylistItem(
            first,
            playlistID: playlistID,
            playlistItems: [first]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        XCTAssertNil(fixture.engine.loadedSources.first?.accessLease)

        let lease = MediaSourceAccessLease(retaining: PlaylistAccessOwner())
        let authorizedFirst = itemWithAccessLease(first, lease: lease)
        fixture.coordinator.prepareForPlaylistSourceRemoval = { _ in true }
        fixture.coordinator.retainedPlaylistItemsProvider = { [authorizedFirst] }
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(roots: [secondRoot], items: [second])
        )
        await fixture.coordinator.removeRoot(firstRoot)
        await waitForScan(fixture.coordinator)
        fixture.coordinator.detachCustomPlaylistQueue(playlistID: playlistID)

        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .fixed)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        XCTAssertEqual(fixture.coordinator.currentItem?.accessLease, lease)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [first.id])
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.playback.isActuallyPlaying)

        fixture.coordinator.playLibraryItem(second)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(fixture.engine.loadedSources.last?.url, second.url)
        XCTAssertEqual(fixture.playback.queueTransitionStyle, .crossfade)
        XCTAssertEqual(fixture.engine.loadedTransitions, [.immediate, .immediate])
        await fixture.coordinator.shutdown()
    }

    func testStaleHandoverDrainCannotClearPreviousItemsResumePosition() async throws {
        let removedURL = URL(fileURLWithPath: "/tmp/Playlist Resume Removed")
        let remainingURL = URL(fileURLWithPath: "/tmp/Playlist Resume Remaining")
        let removedRoot = MediaLibraryRoot(url: removedURL, displayName: "Removed")
        let remainingRoot = MediaLibraryRoot(url: remainingURL, displayName: "Remaining")
        let first = makeItem(rootURL: removedURL, name: "A", path: "A.mov")
        let resumed = makeItem(rootURL: remainingURL, name: "B", path: "B.mov")
        let replacement = makeItem(rootURL: remainingURL, name: "C", path: "C.mov")
        let store = HandoverPlaybackProgressStore(positions: [resumed.id: 25])
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [removedRoot, remainingRoot], items: [first, resumed, replacement]
            ), playbackProgressStore: store
        )
        fixture.session.restoredURLs = [removedURL, remainingURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let lease = MediaSourceAccessLease(retaining: PlaylistAccessOwner())
        let authorizedFirst = itemWithAccessLease(first, lease: lease)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.prepareForPlaylistSourceRemoval = { _ in true }
        fixture.coordinator.retainedPlaylistItemsProvider = { [authorizedFirst] }
        fixture.coordinator.playCustomPlaylistItem(
            first, playlistID: playlistID, playlistItems: [first, resumed, replacement]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        await fixture.coordinator.removeRoot(removedRoot)
        XCTAssertEqual(fixture.coordinator.currentItemID, first.id)
        let gate = HandoverDrainGate()
        fixture.engine.pendingWorkDrainer = {
            if fixture.engine.loadedSources.last?.url == resumed.url {
                await gate.wait()
            }
        }
        fixture.coordinator.playCustomPlaylistItem(
            resumed, playlistID: playlistID,
            playlistItems: [authorizedFirst, resumed, replacement]
        )
        for _ in 0..<1_000 {
            if gate.isWaiting { break }
            await Task.yield()
        }
        guard gate.isWaiting else {
            gate.release()
            fixture.engine.pendingWorkDrainer = nil
            await fixture.coordinator.shutdown()
            return XCTFail("The resumed item's handover drain must be suspended")
        }
        XCTAssertEqual(fixture.playback.currentTime, 25)

        fixture.coordinator.playCustomPlaylistItem(
            replacement, playlistID: playlistID,
            playlistItems: [authorizedFirst, resumed, replacement]
        )
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.currentItemID, replacement.id)
        XCTAssertEqual(fixture.playback.currentTime, 0)
        gate.release()
        fixture.engine.pendingWorkDrainer = nil
        // Shutdown awaits every outstanding load task, including the old task
        // that already stopped being current before it entered the drain.
        await fixture.coordinator.shutdown()

        let position = await store.position(for: resumed.id)
        let removedIDs = await store.removedIDs
        XCTAssertEqual(position, 25)
        XCTAssertFalse(removedIDs.contains(resumed.id))
    }

    func testFailedPlaylistAccessPreservationKeepsLibrarySourceAndPlayback()
        async
    {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Preservation Failure")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let item = makeItem(rootURL: rootURL, name: "Clip", path: "Clip.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [root], items: [item])
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            item,
            playlistID: playlistID,
            playlistItems: [item]
        )
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.playback.setPlaybackIntent(.paused)
        var requestedRoots: [MediaLibraryRoot.ID] = []
        fixture.coordinator.prepareForPlaylistSourceRemoval = { source in
            requestedRoots.append(source.id)
            return false
        }

        await fixture.coordinator.removeRoot(root)

        XCTAssertEqual(requestedRoots, [root.id])
        XCTAssertTrue(fixture.coordinator.sourceRemovalPreservationFailed)
        XCTAssertEqual(fixture.coordinator.roots, [root])
        XCTAssertEqual(fixture.coordinator.items, [item])
        XCTAssertTrue(fixture.session.preparedRemovalURLs.isEmpty)
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)
        XCTAssertEqual(fixture.session.restoredURLs, [rootURL])
        XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [item.id])
        XCTAssertEqual(
            fixture.coordinator.activePlaybackCollection,
            .customPlaylist(playlistID)
        )
        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.playback.readiness, .ready)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)
        XCTAssertFalse(fixture.playback.isActuallyPlaying)
        await fixture.coordinator.shutdown()
    }

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

    func testBridgeDoesNotRebuildIndexForScanStateChanges() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Index Revision")
        let item = makeItem(rootURL: rootURL, name: "Sky", path: "Sky.mov")
        let snapshot = MediaLibrarySnapshot(
            roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
            items: [item]
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: snapshot)
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "Favorites")
        _ = try collection.add(items: [item], to: playlistID)
        let playlists = CustomPlaylistController(
            store: CustomPlaylistPlaybackStore(collection: collection)
        )
        let bridge = CustomPlaylistPlaybackBridge(
            playlists: playlists, library: fixture.coordinator
        )
        await bridge.startAndWait()
        XCTAssertEqual(playlists.resolutionIndexRecomputationCount, 1)
        let previousRevision = fixture.coordinator.itemsRevision
        fixture.scanner.enqueueSnapshot(snapshot)
        fixture.coordinator.refresh()
        XCTAssertEqual(fixture.coordinator.scanState, .scanning)
        XCTAssertEqual(playlists.resolutionIndexRecomputationCount, 1)
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(
            playlists.resolutionIndexRecomputationCount,
            fixture.coordinator.itemsRevision == previousRevision ? 1 : 2
        )
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testBridgeWithNoPlaylistsDoesNotAllocateLibraryIndex() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Empty Playlist Index")
        let item = makeItem(rootURL: rootURL, name: "Sky", path: "Sky.mov")
        let snapshot = MediaLibrarySnapshot(
            roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
            items: [item]
        )
        let fixture = makeFixture(selectedURLs: [], snapshot: snapshot)
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        let playlists = CustomPlaylistController(
            store: CustomPlaylistPlaybackStore(collection: .empty)
        )
        let bridge = CustomPlaylistPlaybackBridge(
            playlists: playlists, library: fixture.coordinator
        )
        await bridge.startAndWait()
        fixture.scanner.enqueueSnapshot(snapshot)
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(playlists.resolutionIndexRecomputationCount, 0)
        XCTAssertFalse(playlists.hasCachedResolutionIndex)
        await bridge.shutdown()
        await fixture.coordinator.shutdown()
    }

    func testBridgeReusesSharedIndexWhenLibraryOrderChanges() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Playlist Sort Revision")
        let first = makeItem(rootURL: rootURL, name: "A", path: "A.mov")
        let second = makeItem(rootURL: rootURL, name: "B", path: "B.mov")
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.session.restoredURLs = [rootURL]
        let start = fixture.coordinator.start()
        _ = await fixture.coordinator.waitForStartupScan(after: start)
        var collection = CustomPlaylistCollection.empty
        let playlistID = try collection.createPlaylist(named: "Favorites")
        try collection.add(items: [first, second], to: playlistID)
        let playlists = CustomPlaylistController(
            store: CustomPlaylistPlaybackStore(collection: collection)
        )
        let bridge = CustomPlaylistPlaybackBridge(playlists: playlists, library: fixture.coordinator)
        await bridge.startAndWait()
        let contentRevision = fixture.coordinator.itemsContentRevision
        let orderedRevision = fixture.coordinator.itemsRevision

        fixture.coordinator.setSortDirection(.descending)
        await playlists.waitForLibraryReconciliation()

        XCTAssertEqual(fixture.coordinator.itemsContentRevision, contentRevision)
        XCTAssertGreaterThan(fixture.coordinator.itemsRevision, orderedRevision)
        XCTAssertEqual(playlists.resolutionIndexRecomputationCount, 1)
        XCTAssertEqual(
            playlists.resolvedItems(
                in: playlistID,
                using: fixture.coordinator.items,
                itemsRevision: fixture.coordinator.itemsRevision
            ),
            [first, second]
        )
        XCTAssertEqual(playlists.resolutionIndexRecomputationCount, 1)
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

private final class PlaylistAccessOwner: @unchecked Sendable {}

private func itemWithAccessLease(
    _ item: LibraryMediaItem,
    lease: MediaSourceAccessLease
) -> LibraryMediaItem {
    LibraryMediaItem(
        rootURL: item.rootURL,
        rootName: item.rootName,
        kind: item.kind,
        url: item.url,
        displayName: item.displayName,
        relativePath: item.relativePath,
        relativeDirectory: item.relativeDirectory,
        creationDate: item.creationDate,
        modificationDate: item.modificationDate,
        fileSize: item.fileSize,
        fileIdentity: item.fileIdentity,
        accessLease: lease
    )
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

@MainActor
private final class HandoverDrainGate {
    private(set) var isWaiting = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor HandoverPlaybackProgressStore: PlaybackProgressStoring {
    private var positions: [LibraryMediaItem.ID: TimeInterval]
    private(set) var removedIDs: Set<LibraryMediaItem.ID> = []

    init(positions: [LibraryMediaItem.ID: TimeInterval]) { self.positions = positions }
    func position(for itemID: LibraryMediaItem.ID) -> TimeInterval? { positions[itemID] }
    func update(position: TimeInterval, duration: TimeInterval, for itemID: LibraryMediaItem.ID) {
        positions[itemID] = PlaybackProgressPolicy.resumablePosition(position: position, duration: duration)
    }
    func removeProgress(for itemIDs: Set<LibraryMediaItem.ID>) {
        removedIDs.formUnion(itemIDs)
        positions = positions.filter { !itemIDs.contains($0.key) }
    }
    func pruneProgress(keeping itemIDs: Set<LibraryMediaItem.ID>, withinRootPaths rootPaths: Set<String>) {
        positions = positions.filter { !rootPaths.contains($0.key.rootPath) || itemIDs.contains($0.key) }
    }
}
