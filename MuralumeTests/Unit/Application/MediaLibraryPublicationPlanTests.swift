import Foundation
import XCTest
@testable import Muralume

final class MediaLibraryPublicationPlanTests: XCTestCase {
    func testLibraryQueueRetainsOnlyMissingItemsOutsideCompleteRoots()
        async throws {
        let available = item("available.mov")
        let deleted = item("deleted.mov")
        let incomplete = item("missing.mov", root: "/LibraryPartial")
        let outside = item("outside.mov", root: "/Other")
        let oldItems = [available, deleted, incomplete, outside]
        let queue = PlaybackQueue(items: oldItems.map(\.id), startingAt: deleted.id)
        let prepared = snapshot(
            items: [available], roots: ["/Library", "/LibraryPartial"],
            incomplete: ["/LibraryPartial"]
        )
        let plan = try await request(
            prepared: prepared, oldItems: oldItems, queue: queue,
            queueItems: oldItems, unavailable: [available.id, deleted.id],
            temporary: [available.id, outside.id], loaded: deleted.id,
            synchronizeLibraryQueue: true
        ).prepare(using: DefaultMediaLibrarySnapshotPreparer())

        var expected = queue
        _ = expected.synchronizeItems([available.id, incomplete.id, outside.id])
        XCTAssertEqual(plan.queue?.makeSnapshot(), expected.makeSnapshot())
        XCTAssertEqual(plan.currentItemID, expected.currentItem)
        XCTAssertNil(plan.loadedItemID)
        XCTAssertEqual(Set(plan.queueItemsByID.keys), Set(expected.items))
        XCTAssertEqual(plan.unavailableItemIDs, [available.id])
        XCTAssertTrue(plan.unavailableChanged)
        XCTAssertEqual(plan.temporaryItemIDs, [outside.id])
        XCTAssertTrue(plan.libraryChanged)
        XCTAssertTrue(plan.queueChanged)
        XCTAssertEqual(plan.keepingItemIDs, [available.id])
        XCTAssertEqual(plan.completeRootPaths, ["/Library"])
    }

    func testFixedQueueRemapsRenamedIdentityWithoutAddingLibraryItems()
        async throws {
        let identity = MediaFileIdentity(
            volumeIdentifier: Data([1]), fileIdentifier: Data([2])
        )
        let old = item("old.mov", identity: identity)
        let renamed = item("renamed.mov", identity: identity)
        let extra = item("extra.mov")
        let plan = try await request(
            prepared: snapshot(items: [renamed, extra]), oldItems: [old],
            queue: PlaybackQueue(items: [old.id]), queueItems: [old],
            loaded: old.id
        ).prepare(using: DefaultMediaLibrarySnapshotPreparer())

        XCTAssertTrue(plan.queueChanged)
        XCTAssertEqual(plan.queue?.items, [renamed.id])
        XCTAssertEqual(plan.currentItemID, renamed.id)
        XCTAssertNil(plan.loadedItemID)
        XCTAssertEqual(plan.queueItemsByID, [renamed.id: renamed])
    }

    func testNilUnchangedQueueRetainsMergedItemsAndDetectsMetadataChanges()
        async throws {
        let old = item("same.mov", size: 1)
        let updated = item("same.mov", size: 2)
        let retained = item("external.mov", root: "/Other")
        let plan = try await request(
            prepared: snapshot(items: [updated]), oldItems: [old], queue: nil,
            queueItems: [old, retained], unavailable: [updated.id]
        ).prepare(using: DefaultMediaLibrarySnapshotPreparer())

        XCTAssertTrue(plan.libraryChanged)
        XCTAssertFalse(plan.queueChanged)
        XCTAssertNil(plan.queue)
        XCTAssertEqual(plan.queueItemsByID, [updated.id: updated, retained.id: retained])
        XCTAssertFalse(plan.unavailableChanged)
    }

    func testEmptyCompleteLibraryClearsChangedQueueAndItemMap() async throws {
        let old = item("deleted.mov")
        let plan = try await request(
            prepared: snapshot(items: []), oldItems: [old],
            queue: PlaybackQueue(items: [old.id]), queueItems: [old],
            unavailable: [old.id], loaded: old.id, synchronizeLibraryQueue: true
        ).prepare(using: DefaultMediaLibrarySnapshotPreparer())

        XCTAssertTrue(plan.queueChanged)
        XCTAssertNil(plan.queue)
        XCTAssertNil(plan.currentItemID)
        XCTAssertNil(plan.loadedItemID)
        XCTAssertTrue(plan.queueItemsByID.isEmpty)
        XCTAssertTrue(plan.unavailableItemIDs.isEmpty)
    }

    func testFailedReplacementLeavesOriginalQueueCurrentAndLoadedUntouched()
        async throws {
        let old = item("old.mov")
        let proposed = item("proposed.mov")
        let queue = PlaybackQueue(items: [old.id])
        let reconciliation = PreparedMediaLibraryQueueReconciliation(
            queueItemsByID: [old.id: old], requiresQueueReplacement: true,
            replacementQueue: nil, currentItemID: proposed.id
        )
        let plan = try await request(
            prepared: snapshot(items: [proposed]), oldItems: [old], queue: queue,
            queueItems: [old], loaded: old.id
        ).prepare(using: ReplacementFailurePreparer(reconciliation: reconciliation))

        XCTAssertFalse(plan.queueChanged)
        XCTAssertEqual(plan.queue?.makeSnapshot(), queue.makeSnapshot())
        XCTAssertEqual(plan.currentItemID, old.id)
        XCTAssertEqual(plan.loadedItemID, old.id)
        XCTAssertEqual(plan.queueItemsByID, [old.id: old])
    }

    func testUnchangedQueueAbovePersistenceLimitKeepsRawQueueAndHistory()
        async throws {
        let ids = (0...PlaybackQueuePolicy.maximumPersistedItemCount).map {
            LibraryMediaItem.ID(rootPath: "/Library", relativePath: "\($0).mov")
        }
        var queue = PlaybackQueue(items: ids)
        _ = queue.moveToNext()
        let originalSnapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertNil(PlaybackQueue<LibraryMediaItem.ID>(snapshot: originalSnapshot))
        let plan = try await request(
            prepared: snapshot(items: []), oldItems: [], queue: queue,
            queueItems: [], loaded: queue.currentItem
        ).prepare(using: DefaultMediaLibrarySnapshotPreparer())

        XCTAssertFalse(plan.libraryChanged)
        XCTAssertFalse(plan.queueChanged)
        XCTAssertEqual(plan.queue?.count, ids.count)
        XCTAssertEqual(plan.queue?.makeSnapshot(), originalSnapshot)
        XCTAssertEqual(plan.loadedItemID, queue.currentItem)
    }

    private func request(
        prepared: PreparedMediaLibrarySnapshot,
        oldItems: [LibraryMediaItem],
        queue: PlaybackQueue<LibraryMediaItem.ID>?,
        queueItems: [LibraryMediaItem],
        unavailable: Set<LibraryMediaItem.ID> = [],
        temporary: Set<LibraryMediaItem.ID> = [],
        loaded: LibraryMediaItem.ID? = nil,
        synchronizeLibraryQueue: Bool = false
    ) -> MediaLibraryPublicationRequest {
        MediaLibraryPublicationRequest(
            prepared: prepared, oldItems: oldItems, queue: queue,
            cachedQueueSnapshot: queue?.makeSnapshot(),
            queueItemsByID: Dictionary(uniqueKeysWithValues: queueItems.map { ($0.id, $0) }),
            unavailableItemIDs: unavailable, temporaryItemIDs: temporary,
            currentItemID: queue?.currentItem, loadedItemID: loaded,
            synchronizeLibraryQueue: synchronizeLibraryQueue
        )
    }

    private func snapshot(
        items: [LibraryMediaItem], roots: [String] = ["/Library"],
        incomplete: Set<String> = []
    ) -> PreparedMediaLibrarySnapshot {
        PreparedMediaLibrarySnapshot(
            roots: roots.map {
                MediaLibraryRoot(url: URL(fileURLWithPath: $0), displayName: $0)
            },
            library: PreparedMediaLibraryItems(
                items: items,
                itemsByID: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            ),
            incompleteRootPaths: incomplete
        )
    }

    private func item(
        _ name: String, root: String = "/Library", size: Int64 = 1,
        identity: MediaFileIdentity? = nil
    ) -> LibraryMediaItem {
        let rootURL = URL(fileURLWithPath: root)
        return LibraryMediaItem(
            rootURL: rootURL, rootName: root,
            url: rootURL.appendingPathComponent(name), displayName: name,
            relativePath: name, relativeDirectory: "", creationDate: nil,
            fileSize: size, fileIdentity: identity
        )
    }
}

private struct ReplacementFailurePreparer: MediaLibrarySnapshotPreparing {
    let reconciliation: PreparedMediaLibraryQueueReconciliation

    func prepare(
        _ snapshot: MediaLibrarySnapshot, requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibrarySnapshot {
        try await DefaultMediaLibrarySnapshotPreparer().prepare(
            snapshot, requestedSourcePaths: requestedSourcePaths, sort: sort
        )
    }

    func merge(
        _ candidates: [LibraryMediaItem], into items: [LibraryMediaItem],
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try await DefaultMediaLibrarySnapshotPreparer().merge(candidates, into: items, sort: sort)
    }

    func sort(
        _ items: [LibraryMediaItem], using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try await DefaultMediaLibrarySnapshotPreparer().sort(items, using: sort)
    }

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) async throws -> PreparedMediaLibraryQueueReconciliation {
        reconciliation
    }
}
