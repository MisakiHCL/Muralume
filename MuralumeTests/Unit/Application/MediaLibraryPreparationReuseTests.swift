import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryPreparationReuseTests: XCTestCase {
    func testFirstUnchangedRefreshAfterQueueInstallReusesPreparedLibrary() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Prepared Library Refresh")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let items = makeItems(root: rootURL)
        let snapshot = MediaLibrarySnapshot(roots: [root], items: items)
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL], snapshot: snapshot, snapshotPreparer: preparer
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.playLibraryItem(items[0])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        let queue = fixture.coordinator.makeQueueSnapshot()
        let itemRevision = fixture.coordinator.itemsRevision
        let queueRevision = fixture.coordinator.queueRevision
        let preparations = await preparer.callCount(for: .prepare)
        let reconciliations = await preparer.callCount(for: .reconcileQueue)

        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        let preparationCount = await preparer.callCount(for: .prepare)
        let reconciliationCount = await preparer.callCount(for: .reconcileQueue)
        XCTAssertEqual(preparationCount, preparations)
        XCTAssertEqual(reconciliationCount, reconciliations + 1)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), queue)
        XCTAssertEqual(fixture.coordinator.queueRevision, queueRevision)
        XCTAssertEqual(fixture.coordinator.itemsRevision, itemRevision)
        await fixture.coordinator.shutdown()
    }

    func testLibrarySelectionRetainsHistoryAndInvalidatesReuseAfterSort() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Prepared Library Selection")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let items = makeItems(root: rootURL)
        let fixture = makeFixture(
            selectedURLs: [rootURL], snapshot: .init(roots: [root], items: items)
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        var expected = PlaybackQueue(items: items.map(\.id), startingAt: items[0].id)
        fixture.coordinator.playLibraryItem(items[0])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.coordinator.playLibraryItem(items[2])
        _ = expected.select(items[2].id)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), expected.makeSnapshot())
        fixture.coordinator.playPrevious()
        _ = expected.moveToPrevious()
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        fixture.coordinator.playLibraryItem(items[1])
        _ = expected.select(items[1].id)
        await waitForLoads(fixture.engine, count: 4)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), expected.makeSnapshot())

        fixture.coordinator.setSortDirection(.descending)
        let reordered = Array(items.reversed())
        _ = expected.synchronizeItems(reordered.map(\.id))
        fixture.coordinator.playLibraryItem(items[0])
        _ = expected.select(items[0].id)
        await waitForLoads(fixture.engine, count: 5)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.items.map(\.id), reordered.map(\.id))
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), expected.makeSnapshot())
        await fixture.coordinator.shutdown()
    }

    func testLibraryQueueReuseRefreshesMetadataAndMembershipAfterScan() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Prepared Library Metadata")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let items = makeItems(root: rootURL)
        let fixture = makeFixture(
            selectedURLs: [rootURL], snapshot: .init(roots: [root], items: items)
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.playLibraryItem(items[0])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let refreshed = makeItem(
            rootURL: rootURL, name: "Clip 1", path: "clip-1.mov", fileSize: 99
        )
        fixture.scanner.enqueueSnapshot(.init(roots: [root], items: [refreshed, items[2]]))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.playLibraryItem(refreshed)
        XCTAssertEqual(fixture.coordinator.currentItem?.fileSize, 99)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [refreshed.id, items[2].id])
        XCTAssertFalse(fixture.coordinator.activeQueueMediaReferences.contains {
            $0.mediaItemID == items[1].id
        })
        await fixture.coordinator.shutdown()
    }

    func testSwitchingFromCustomQueueRestoresWholePreparedLibrary() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Prepared Library Membership")
        let root = MediaLibraryRoot(url: rootURL, displayName: "Library")
        let items = makeItems(root: rootURL)
        let fixture = makeFixture(
            selectedURLs: [rootURL], snapshot: .init(roots: [root], items: items)
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.playLibraryItem(items[0])
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let playlistID = CustomPlaylist.ID()
        fixture.coordinator.playCustomPlaylistItem(
            items[1], playlistID: playlistID, playlistItems: Array(items.prefix(2))
        )
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, Array(items.prefix(2)).map(\.id))
        fixture.coordinator.playLibraryItem(items[2])
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .mediaLibrary)
        XCTAssertEqual(fixture.coordinator.currentItemID, items[2].id)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, items.map(\.id))
        await fixture.coordinator.shutdown()
    }

    private func makeItems(root: URL) -> [LibraryMediaItem] {
        (1...3).map {
            makeItem(rootURL: root, name: "Clip \($0)", path: "clip-\($0).mov", fileSize: Int64($0))
        }
    }
}
