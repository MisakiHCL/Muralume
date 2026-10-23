import Combine
import Foundation
import XCTest
@testable import Muralume

final class MediaCollectionSearchTests: XCTestCase {
    func testWhitespaceOnlyQueryReturnsItemsInOriginalOrder() {
        let items = [
            makeItem(name: "Clouds", relativePath: "Sky/Clouds.mov"),
            makeItem(name: "Ocean", relativePath: "Travel/Ocean.mov")
        ]

        let result = MediaCollectionSearch(query: " \n\t ")
            .filteredItems(from: items)

        XCTAssertEqual(result, items)
    }

    func testItemSearchUsesLocalizedStandardMatchingAcrossAllFields() {
        let nameMatch = makeItem(
            name: "Résumé 02",
            relativePath: "Work/CV.mov",
            rootName: "Archive"
        )
        let pathMatch = makeItem(
            name: "Morning",
            relativePath: "Trips/Tokyo 10.mov",
            rootName: "Archive"
        )
        let directoryMatch = makeItem(
            name: "Evening",
            relativePath: "Northern Lights/Aurora.mov",
            rootName: "Archive"
        )
        let rootMatch = makeItem(
            name: "Clouds",
            relativePath: "Clouds.mov",
            rootName: "SKY LIBRARY"
        )

        XCTAssertEqual(
            MediaCollectionSearch(query: "  resume 02 ")
                .filteredItems(from: [pathMatch, nameMatch]),
            [nameMatch]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "tokyo 10")
                .filteredItems(from: [nameMatch, pathMatch]),
            [pathMatch]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "northern lights")
                .filteredItems(from: [directoryMatch, pathMatch]),
            [directoryMatch]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "sky library")
                .filteredItems(from: [rootMatch, nameMatch]),
            [rootMatch]
        )
    }

    func testFilteringKeepsMatchingItemOrder() {
        let first = makeItem(
            name: "First",
            relativePath: "Travel/First.mov"
        )
        let nonmatch = makeItem(
            name: "Other",
            relativePath: "Studio/Other.mov"
        )
        let second = makeItem(
            name: "Second",
            relativePath: "Travel/Second.mov"
        )

        XCTAssertEqual(
            MediaCollectionSearch(query: "travel")
                .filteredItems(from: [first, nonmatch, second]),
            [first, second]
        )
    }

    func testChineseExactAndSubstringQueriesMatchImmediately() {
        let exactMatch = makeItem(
            name: "在路上",
            relativePath: "旅行/在路上.mov"
        )
        let substringMatch = makeItem(
            name: "不在场",
            relativePath: "电影/不在场.mov"
        )

        XCTAssertEqual(
            MediaCollectionSearch(query: "\u{3000}在路上\u{3000}")
                .filteredItems(from: [substringMatch, exactMatch]),
            [exactMatch]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "在")
                .filteredItems(from: [substringMatch, exactMatch]),
            [substringMatch, exactMatch]
        )
    }

    func testOfflinePlaylistEntriesMatchLastKnownNameAndPathInformation() {
        let byName = makeEntry(
            name: "Blue Sky",
            rootPath: "/Volumes/Archive",
            relativePath: "Old/Clouds.mov"
        )
        let byRelativePath = makeEntry(
            name: "Ocean",
            rootPath: "/Volumes/Archive",
            relativePath: "Travel/Iceland/Waterfall.mov"
        )
        let byRootPath = makeEntry(
            name: "Mountain",
            rootPath: "/Volumes/Remote Journeys",
            relativePath: "Mountain.mov"
        )

        XCTAssertEqual(
            MediaCollectionSearch(query: "blue sky")
                .filteredEntries(
                    from: [byRelativePath, byName, byRootPath]
                ),
            [byName]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "iceland")
                .filteredEntries(
                    from: [byName, byRelativePath, byRootPath]
                ),
            [byRelativePath]
        )
        XCTAssertEqual(
            MediaCollectionSearch(query: "remote journeys")
                .filteredEntries(
                    from: [byName, byRootPath, byRelativePath]
                ),
            [byRootPath]
        )
    }

    func testOfflinePlaylistFilteringKeepsEntryOrder() {
        let first = makeEntry(
            name: "First",
            rootPath: "/Library",
            relativePath: "Sky/First.mov"
        )
        let nonmatch = makeEntry(
            name: "Other",
            rootPath: "/Library",
            relativePath: "Travel/Other.mov"
        )
        let second = makeEntry(
            name: "Second",
            rootPath: "/Library",
            relativePath: "Sky/Second.mov"
        )

        XCTAssertEqual(
            MediaCollectionSearch(query: "sky")
                .filteredEntries(from: [first, nonmatch, second]),
            [first, second]
        )
    }

    func testLibraryProjectionCacheScansTenThousandItemsOncePerKey() {
        let items = makeLargeItemCollection(count: 10_000)
        let cache = MediaLibrarySearchProjectionCache()

        let first = cache.projection(
            query: "batch-7",
            itemsRevision: 41,
            items: items
        )

        XCTAssertEqual(first.items.count, 1_000)
        XCTAssertEqual(cache.recomputationCount, 1)

        let sameNormalizedQuery = cache.projection(
            query: "  batch-7  ",
            itemsRevision: 41,
            items: items
        )
        XCTAssertEqual(sameNormalizedQuery.items, first.items)
        XCTAssertEqual(cache.recomputationCount, 1)

        _ = cache.projection(
            query: "batch-8",
            itemsRevision: 41,
            items: items
        )
        XCTAssertEqual(cache.recomputationCount, 2)

        _ = cache.projection(
            query: "batch-8",
            itemsRevision: 42,
            items: items
        )
        XCTAssertEqual(cache.recomputationCount, 3)
    }

    func testPlaylistProjectionCachesTenThousandEntryFilterAndResolution() {
        let items = makeLargeItemCollection(count: 10_000)
        let entries = items.map {
            CustomPlaylistEntry(media: MediaReference(item: $0))
        }
        let playlist = CustomPlaylist(
            name: "Large",
            entries: entries,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let cache = CustomPlaylistDetailProjectionCache()

        let first = cache.projection(
            playlist: playlist,
            playlistRevision: 7,
            query: "batch-7",
            libraryItems: items,
            libraryItemsRevision: 11
        )

        XCTAssertEqual(first.entries.count, 1_000)
        XCTAssertEqual(first.resolvedItemsByEntryID.count, 1_000)
        XCTAssertEqual(
            first.entryID(for: items[9_997].id),
            entries[9_997].id
        )
        XCTAssertEqual(cache.recomputationCount, 1)
        XCTAssertEqual(cache.resolutionIndexRecomputationCount, 1)

        let sameKey = cache.projection(
            playlist: playlist,
            playlistRevision: 7,
            query: " batch-7 ",
            libraryItems: items,
            libraryItemsRevision: 11
        )
        XCTAssertEqual(sameKey.entries.map(\.id), first.entries.map(\.id))
        XCTAssertEqual(cache.recomputationCount, 1)
        XCTAssertEqual(cache.resolutionIndexRecomputationCount, 1)

        _ = cache.projection(
            playlist: playlist,
            playlistRevision: 7,
            query: "batch-8",
            libraryItems: items,
            libraryItemsRevision: 11
        )
        XCTAssertEqual(cache.recomputationCount, 2)
        XCTAssertEqual(cache.resolutionIndexRecomputationCount, 1)

        _ = cache.projection(
            playlist: playlist,
            playlistRevision: 8,
            query: "batch-7",
            libraryItems: items,
            libraryItemsRevision: 11
        )
        XCTAssertEqual(cache.recomputationCount, 3)
        XCTAssertEqual(cache.resolutionIndexRecomputationCount, 1)

        _ = cache.projection(
            playlist: playlist,
            playlistRevision: 8,
            query: "batch-7",
            libraryItems: items,
            libraryItemsRevision: 12
        )
        XCTAssertEqual(cache.recomputationCount, 4)
        XCTAssertEqual(cache.resolutionIndexRecomputationCount, 2)
    }

    func testCancelledFilteringStopsBeforeScanning() async {
        let items = makeLargeItemCollection(count: 10_000)
        let search = MediaCollectionSearch(query: "batch")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try search.filteredItemsCancellable(from: items)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled filtering should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellableFilteringPreservesLocalizedMatchingAndOrder() throws {
        let items = makeLargeItemCollection(count: 10_000)
        let search = MediaCollectionSearch(query: "  batch-7  ")
        XCTAssertEqual(
            try search.filteredItemsCancellable(from: items),
            search.filteredItems(from: items)
        )
        let entries = items.map { CustomPlaylistEntry(media: MediaReference(item: $0)) }
        XCTAssertEqual(
            try search.filteredEntriesCancellable(from: entries),
            search.filteredEntries(from: entries)
        )
    }

    @MainActor
    func testLatestSearchCoalescesPendingWorkAndRejectsOldRevision() async {
        let gate = MediaSearchTestGate()
        let search = LatestMediaSearch<Int>()
        let firstKey = MediaLibrarySearchRequestID(itemsRevision: 1, query: "sky")
        let latestKey = MediaLibrarySearchRequestID(itemsRevision: 2, query: "sky")
        search.request(key: firstKey) {
            await gate.suspend()
            return 1 // Deliberately ignores cancellation to test publication.
        }
        await gate.waitUntilSuspended()
        search.request(key: "superseded") {
            await gate.record(2)
            return 2
        }
        search.request(key: latestKey) {
            await gate.record(3)
            return 3
        }
        XCTAssertNil(search.result(for: firstKey))
        XCTAssertNil(search.result(for: latestKey))
        let startedBeforeRelease = await gate.recordedValues
        XCTAssertTrue(startedBeforeRelease.isEmpty)
        await gate.release()
        await search.waitForPendingSearch()
        let startedAfterRelease = await gate.recordedValues
        XCTAssertEqual(startedAfterRelease, [3])
        XCTAssertNil(search.result(for: firstKey))
        XCTAssertEqual(search.result(for: latestKey), 3)
    }

    @MainActor
    func testLeavingSearchDiscardsPendingAndInFlightResults() async {
        let gate = MediaSearchTestGate()
        let search = LatestMediaSearch<Int>()
        search.request(key: "first") {
            await gate.suspend()
            return 1
        }
        await gate.waitUntilSuspended()
        search.request(key: "pending") {
            await gate.record(2)
            return 2
        }
        search.cancel()
        await gate.release()
        await search.waitForPendingSearch()
        let started = await gate.recordedValues
        XCTAssertTrue(started.isEmpty)
        XCTAssertNil(search.result(for: "first"))
        XCTAssertNil(search.result(for: "pending"))
        search.request(key: "first") { 3 }
        await search.waitForPendingSearch()
        XCTAssertEqual(search.result(for: "first"), 3)
        search.cancel()
        XCTAssertNil(search.result(for: "first"))
    }

    private nonisolated static func isMainThreadSnapshot() -> Bool {
        Thread.isMainThread
    }

    @MainActor
    func testSearchRunsOffMainThread() async {
        let search = LatestMediaSearch<Bool>()
        search.request(key: "thread") { Self.isMainThreadSnapshot() }
        await search.waitForPendingSearch()
        XCTAssertEqual(search.result(for: "thread"), false)
    }

    @MainActor
    func testCancelledRequestCannotPublishWhenSameSearchIsReopened() async {
        let gate = MediaSearchTestGate()
        let search = LatestMediaSearch<Int>()
        search.request(key: "sky") {
            await gate.suspend()
            return 1
        }
        await gate.waitUntilSuspended()
        search.cancel()
        var observedValues: [Int] = []
        let observation = search.objectWillChange.sink {
            if let value = search.result(for: "sky") { observedValues.append(value) }
        }
        search.request(key: "sky") { 3 }
        await gate.release()
        await search.waitForPendingSearch()
        XCTAssertEqual(search.result(for: "sky"), 3)
        XCTAssertFalse(observedValues.contains(1))
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testSamePlaylistQueryKeepsAppliedTableSnapshotDuringRevisionRefresh() async throws {
        let search = LatestMediaSearch<Int>()
        let playlistID = CustomPlaylist.ID()
        let previousKey = CustomPlaylistSearchRequestID(
            playlistID: playlistID, playlistRevision: 1,
            libraryItemsRevision: 1, query: "sky"
        )
        let nextKey = CustomPlaylistSearchRequestID(
            playlistID: playlistID, playlistRevision: 2,
            libraryItemsRevision: 2, query: "sky"
        )
        search.request(key: previousKey) { 1 }
        await search.waitForPendingSearch()
        var tracker = VirtualizedTableUpdateTracker()
        XCTAssertTrue(tracker.consumeSnapshotToken(AnyHashable(previousKey)))
        let gate = MediaSearchTestGate()
        search.request(key: nextKey) {
            await gate.suspend()
            return 2
        }
        await gate.waitUntilSuspended()
        let retained = try XCTUnwrap(search.latestResult(compatibleWith: nextKey) {
            $0.playlistID == $1.playlistID && $0.query == $1.query
        })
        XCTAssertEqual(retained.key, previousKey)
        XCTAssertEqual(retained.result, 1)
        XCTAssertFalse(tracker.consumeSnapshotToken(AnyHashable(retained.key)))
        let differentQuery = CustomPlaylistSearchRequestID(
            playlistID: playlistID, playlistRevision: 2,
            libraryItemsRevision: 2, query: "ocean"
        )
        XCTAssertNil(search.latestResult(compatibleWith: differentQuery) {
            $0.playlistID == $1.playlistID && $0.query == $1.query
        })
        await gate.release()
        await search.waitForPendingSearch()
        XCTAssertEqual(search.result(for: nextKey), 2)
        XCTAssertTrue(tracker.consumeSnapshotToken(AnyHashable(nextKey)))
        search.cancel()
        XCTAssertNil(search.latestResult(compatibleWith: nextKey) { $0 == $1 })
    }

    private func makeItem(
        name: String,
        relativePath: String,
        rootName: String = "Library"
    ) -> LibraryMediaItem {
        let rootURL = URL(fileURLWithPath: "/Library")
        return LibraryMediaItem(
            rootURL: rootURL,
            rootName: rootName,
            url: rootURL.appendingPathComponent(relativePath),
            displayName: name,
            relativePath: relativePath,
            relativeDirectory: (relativePath as NSString)
                .deletingLastPathComponent,
            creationDate: nil,
            fileSize: 1
        )
    }

    private func makeEntry(
        name: String,
        rootPath: String,
        relativePath: String
    ) -> CustomPlaylistEntry {
        CustomPlaylistEntry(
            media: MediaReference(
                mediaItemID: LibraryMediaItem.ID(
                    rootPath: rootPath,
                    relativePath: relativePath
                ),
                fileIdentity: nil,
                lastKnownDisplayName: name
            )
        )
    }

    private func makeLargeItemCollection(
        count: Int
    ) -> [LibraryMediaItem] {
        (0..<count).map { index in
            makeItem(
                name: "Clip-\(index)",
                relativePath: "Batch-\(index % 10)/Clip-\(index).mov"
            )
        }
    }
}

private actor MediaSearchTestGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private(set) var recordedValues: [Int] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            suspensionWaiter?.resume()
            suspensionWaiter = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspended == nil else { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }

    func release() {
        suspended?.resume()
        suspended = nil
    }

    func record(_ value: Int) {
        recordedValues.append(value)
    }
}
