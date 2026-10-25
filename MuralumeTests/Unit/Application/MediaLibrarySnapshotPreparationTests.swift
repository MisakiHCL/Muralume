import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaLibrarySnapshotPreparationTests: XCTestCase {
    private let preparer = DefaultMediaLibrarySnapshotPreparer()
    private let rootURL = URL(fileURLWithPath: "/SyntheticPreparation")

    func testPreparationAndMergeMatchPublicSortForEveryPolicyAndInputShape() async throws {
        let names = ["Clip 10", "Clip 2", "clip 02", "Café", "Cafe\u{301}", "片段 12", "片段 3", "A", "A"]
        let values = names.enumerated().map { index, name in
            item("Group\(index % 3)/\(index).mov", name: name,
                 size: Int64(index % 3), created: index.isMultiple(of: 3) ? nil : Double(index % 4))
        }
        let shapes = [values, Array(values.reversed()), Array(values.dropFirst(3) + values.prefix(3))]
        for field in MediaLibrarySortField.allCases {
            for direction in MediaLibrarySortDirection.allCases {
                let sort = MediaLibrarySort(field: field, direction: direction)
                let expected = sort.sorted(values)
                for input in shapes {
                    let prepared = try await prepare(input, sort: sort)
                    XCTAssertEqual(prepared.library.items, expected)
                    XCTAssertEqual(prepared.library.preparedQueueItems.items, expected.map(\.id))
                    let merged = try await preparer.merge(
                        Array(input.suffix(4)), into: Array(input.dropLast(4)), sort: sort
                    )
                    XCTAssertEqual(merged.items, expected)
                    let sorted = try await preparer.sort(input, using: sort)
                    XCTAssertEqual(sorted.items, expected)
                }
            }
        }
    }

    func testDuplicateNormalizedIDsKeepLastValueAndOriginalDictionaryKeyRepresentation() async throws {
        let first = item("Nested/clip.mov", name: "First", size: 1)
        let last = item("clip.mov", name: "Last", size: 9,
                        root: rootURL.appendingPathComponent("Nested"))
        XCTAssertEqual(first.id, last.id)
        let prepared = try await preparer.prepare(
            MediaLibrarySnapshot(roots: [], items: [first, last]),
            requestedSourcePaths: [first.id.rootPath, last.id.rootPath],
            sort: MediaLibrarySort()
        )
        XCTAssertEqual(prepared.library.items, [last])
        XCTAssertEqual(prepared.library.itemsByID[first.id], last)
        XCTAssertEqual(prepared.library.itemsByID.keys.first?.rootPath, first.id.rootPath)
        XCTAssertEqual(prepared.library.itemsByID.keys.first?.relativePath, first.id.relativePath)
        let matches = try prepared.library.temporaryPlaybackSnapshot.matches(
            canonicalPaths: [last.url.path], canonicalPath: { $0.path }
        )
        XCTAssertEqual(matches.items, [last])
    }

    func testMetadataOnlyChangesReuseOrderingButRefreshAllContentIndexes() async throws {
        let oldIdentity = identity(1)
        let newIdentity = identity(2)
        let old = item("same.mov", name: "Clip 2", size: 3, created: 10,
                       modified: 11, identity: oldIdentity)
        let other = item("other.mov", name: "Clip 10", size: 4, created: 20)
        let initial = try await prepare([other, old])
        let updated = item("same.mov", name: "Clip 2", size: 99, created: 50,
                           modified: 51, identity: newIdentity)
        let revised = try await prepare([other, updated], previous: initial.library)
        XCTAssertEqual(revised.library.items, [updated, other])
        assertReusedOrdering(revised.library, initial.library)
        XCTAssertNotEqual(revised.library.resolutionIndex.storageIdentityForTesting,
                          initial.library.resolutionIndex.storageIdentityForTesting)
        XCTAssertEqual(revised.library.itemsByID[old.id], updated)
        XCTAssertEqual(revised.library.preparedQueueItems.items,
                       initial.library.preparedQueueItems.items)
        XCTAssertNil(revised.library.resolutionIndex.resolve(MediaReference(
            mediaItemID: .init(rootPath: "/Missing", relativePath: "old.mov"),
            fileIdentity: oldIdentity, lastKnownDisplayName: "Old"
        )))
        let matches = try revised.library.temporaryPlaybackSnapshot.matches(
            canonicalPaths: [updated.url.path], canonicalPath: { $0.path }
        )
        XCTAssertEqual(matches.items, [updated])
    }

    func testIdenticalValuesWithChangedDictionaryKeyRepresentationRefreshMetadata() async throws {
        let outer = item("Nested/clip.mov", name: "First")
        let inner = item("clip.mov", name: "Last", root: rootURL.appendingPathComponent("Nested"))
        let paths: Set<String> = [outer.id.rootPath, inner.id.rootPath]
        let initial = try await preparer.prepare(
            MediaLibrarySnapshot(roots: [], items: [outer, inner]),
            requestedSourcePaths: paths, sort: MediaLibrarySort()
        )
        let incoming = MediaLibrarySnapshot(roots: [], items: [inner])
        let fresh = try await preparer.prepare(
            incoming, requestedSourcePaths: paths, sort: MediaLibrarySort()
        )
        let reused = try await preparer.prepare(
            incoming, requestedSourcePaths: paths, sort: MediaLibrarySort(),
            previousLibrary: initial.library, previousSort: MediaLibrarySort()
        )
        XCTAssertEqual(initial.library.items, fresh.library.items)
        XCTAssertEqual(reused.library.items, fresh.library.items)
        let reusedKey = try XCTUnwrap(reused.library.itemsByID.keys.first)
        let freshKey = try XCTUnwrap(fresh.library.itemsByID.keys.first)
        XCTAssertEqual(reusedKey.rootPath, freshKey.rootPath)
        XCTAssertEqual(reusedKey.relativePath, freshKey.relativePath)
        XCTAssertEqual(reusedKey.rootPath, inner.id.rootPath)
        XCTAssertNotEqual(reused.library.resolutionIndex.storageIdentityForTesting,
                          initial.library.resolutionIndex.storageIdentityForTesting)
        assertReusedOrdering(reused.library, initial.library)
    }

    func testIdenticalContentSharesPreparedLookupStorageDespiteIncomingOrder() async throws {
        let values = [item("b.mov", name: "Clip 2"), item("a.mov", name: "Clip 10")]
        let initial = try await prepare(values)
        let repeated = try await prepare(Array(values.reversed()), previous: initial.library)
        assertReusedOrdering(repeated.library, initial.library)
        XCTAssertEqual(repeated.library.resolutionIndex.storageIdentityForTesting,
                       initial.library.resolutionIndex.storageIdentityForTesting)
        XCTAssertEqual(repeated.library.items, initial.library.items)
    }

    func testSortKeysInvalidateReuseForEachFieldAndDirection() async throws {
        let original = [item("a.mov", name: "A", size: 1, created: nil),
                        item("b.mov", name: "B", size: 2, created: 20)]
        for field in MediaLibrarySortField.allCases {
            for direction in MediaLibrarySortDirection.allCases {
                let sort = MediaLibrarySort(field: field, direction: direction)
                let initial = try await prepare(original, sort: sort)
                let changed = [item("a.mov", name: field == .name ? "Z" : "A",
                                    size: field == .fileSize ? 99 : 1,
                                    created: field == .creationDate ? 99 : nil), original[1]]
                let revised = try await prepare(changed, sort: sort, previous: initial.library,
                                                previousSort: sort)
                XCTAssertEqual(revised.library.items, sort.sorted(changed))
                assertRebuiltOrdering(revised.library, initial.library)
            }
        }
    }

    func testNonOrderingMetadataReusesDateAndSizeOrder() async throws {
        let original = [item("a.mov", name: "A", size: 1, created: 10),
                        item("b.mov", name: "B", size: 2, created: 20)]
        for field in [MediaLibrarySortField.creationDate, .fileSize] {
            let sort = MediaLibrarySort(field: field, direction: .descending)
            let initial = try await prepare(original, sort: sort)
            let changed = [item("a.mov", name: "A", size: 1, created: 10, modified: 99), original[1]]
            let revised = try await prepare(changed, sort: sort, previous: initial.library,
                                            previousSort: sort)
            assertReusedOrdering(revised.library, initial.library)
            XCTAssertEqual(revised.library.items, sort.sorted(changed))
        }
    }

    func testMembershipNamesAndIDRepresentationsInvalidateOrderingReuse() async throws {
        let a = item("Nested/a.mov", name: "A")
        let b = item("b.mov", name: "B")
        let initial = try await prepare([a, b])
        let represented = item("a.mov", name: "A", root: rootURL.appendingPathComponent("Nested"))
        let cases = [[a], [a, b, item("c.mov", name: "C")],
                     [a, item("c.mov", name: "C")],
                     [item("Nested/a.mov", name: "Z"), b], [represented, b]]
        for values in cases {
            let paths = Set(values.map { $0.id.rootPath })
            let revised = try await preparer.prepare(
                MediaLibrarySnapshot(roots: [], items: values),
                requestedSourcePaths: paths, sort: MediaLibrarySort(),
                previousLibrary: initial.library, previousSort: MediaLibrarySort()
            )
            assertRebuiltOrdering(revised.library, initial.library)
            XCTAssertEqual(revised.library.items, MediaLibrarySort().sorted(values))
        }
    }

    func testChangedPolicyOrLocaleAndUnstampedInputsCannotReuseOrder() async throws {
        let values = [item("a.mov", name: "A"), item("b.mov", name: "B")]
        let initial = try await prepare(values)
        let descending = MediaLibrarySort(field: .name, direction: .descending)
        let policyChanged = try await prepare(values, sort: descending, previous: initial.library)
        XCTAssertEqual(policyChanged.library.items, Array(initial.library.items.reversed()))
        assertRebuiltOrdering(policyChanged.library, initial.library)
        let foreign = Locale.current == Locale(identifier: "en_US_POSIX")
            ? Locale(identifier: "ja_JP") : Locale(identifier: "en_US_POSIX")
        for context in [nil, PreparedMediaLibraryOrdering(sort: MediaLibrarySort(), locale: foreign)] {
            let unstamped = PreparedMediaLibraryItems(
                items: Array(values.reversed()), itemsByID: initial.library.itemsByID,
                orderingContext: context
            )
            let revised = try await prepare(values, previous: unstamped)
            XCTAssertEqual(revised.library.items, initial.library.items)
            XCTAssertNotEqual(revised.library.orderingContext?.storageIdentityForTesting,
                              context?.storageIdentityForTesting)
        }
    }

    func testRequestedRootAndCompletenessFilteringArePreserved() async throws {
        let allowed = item("a.mov", name: "A")
        let excluded = item("b.mov", name: "B", root: URL(fileURLWithPath: "/OtherSynthetic"))
        let root = MediaLibraryRoot(url: rootURL, displayName: "Synthetic")
        let otherRoot = MediaLibraryRoot(url: excluded.rootURL, displayName: "Other")
        let prepared = try await preparer.prepare(
            MediaLibrarySnapshot(roots: [root, otherRoot], items: [excluded, allowed],
                                 incompleteRootPaths: [root.id.standardizedPath, otherRoot.id.standardizedPath]),
            requestedSourcePaths: [root.id.standardizedPath], sort: MediaLibrarySort()
        )
        XCTAssertEqual(prepared.roots, [root])
        XCTAssertEqual(prepared.library.items, [allowed])
        XCTAssertEqual(prepared.incompleteRootPaths, [root.id.standardizedPath])
    }

    func testCancelledPreparationAndCancellableSortRejectBeforeWork() async throws {
        let values = [item("a.mov", name: "A")]
        let initial = try await prepare(values)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preparer.prepare(
                MediaLibrarySnapshot(roots: [], items: values),
                requestedSourcePaths: [rootURL.path], sort: MediaLibrarySort(),
                previousLibrary: initial.library, previousSort: MediaLibrarySort()
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let sortTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MediaLibrarySort().sortedCancellable(values)
        }
        do { _ = try await sortTask.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testExactReconciliationRefreshesValuesAndKeepsQueueHistory() async throws {
        let a = item("a.mov", name: "A", size: 1)
        let b = item("b.mov", name: "B", size: 2)
        var queue = PlaybackQueue(items: [a.id, b.id])
        _ = queue.moveToNext()
        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        let updated = item("a.mov", name: "A", size: 99)
        let available = [a.id: updated, b.id: b]
        let result = try await preparer.reconcileQueue(
            snapshot: snapshot, queueItemsByID: [a.id: a, b.id: b],
            availableItemsByID: available,
            resolutionIndex: MediaReferenceResolutionIndex(itemsByID: available)
        )
        XCTAssertFalse(result.requiresQueueReplacement)
        XCTAssertNil(result.replacementQueue)
        XCTAssertEqual(result.currentItemID, b.id)
        XCTAssertEqual(result.queueItemsByID, available)
        XCTAssertEqual(queue.makeSnapshot(), snapshot)
    }

    func testIdentityFallbackStillRespectsExactClaims() async throws {
        let shared = identity(1)
        let old = item("old.mov", name: "Old", identity: shared)
        let exact = item("exact.mov", name: "Exact", identity: shared)
        let queue = PlaybackQueue(items: [old.id, exact.id])
        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        let result = try await preparer.reconcileQueue(
            snapshot: snapshot, queueItemsByID: [old.id: old, exact.id: exact],
            availableItemsByID: [exact.id: exact],
            resolutionIndex: MediaReferenceResolutionIndex(items: [exact])
        )
        XCTAssertEqual(result.queueItemsByID, [old.id: old, exact.id: exact])
        XCTAssertFalse(result.requiresQueueReplacement)
    }

    func testHistoryRepresentationChangeFallsBackToCanonicalRemapping() async throws {
        let a = item("Nested/a.mov", name: "A")
        let b = item("b.mov", name: "B")
        let legacy = item("a.mov", name: "A", root: rootURL.appendingPathComponent("Nested"))
        var queue = PlaybackQueue(items: [a.id, b.id])
        _ = queue.moveToNext()
        let original = try XCTUnwrap(queue.makeSnapshot())
        let snapshot = PlaybackQueueSnapshot(
            items: original.items, order: original.order, currentItem: original.currentItem,
            roundNumber: original.roundNumber, currentRoundPosition: original.currentRoundPosition,
            remainingItems: original.remainingItems, remainingIndex: original.remainingIndex,
            history: [.init(item: legacy.id, roundNumber: 1, position: 1)], forwardHistory: []
        )
        let available = [a.id: a, b.id: b]
        let result = try await preparer.reconcileQueue(
            snapshot: snapshot, queueItemsByID: available, availableItemsByID: available,
            resolutionIndex: MediaReferenceResolutionIndex(itemsByID: available)
        )
        XCTAssertTrue(result.requiresQueueReplacement)
        let historyID = try XCTUnwrap(result.replacementQueue?.makeSnapshot()?.history.first?.item)
        XCTAssertEqual(historyID.rootPath, a.id.rootPath)
        XCTAssertEqual(historyID.relativePath, a.id.relativePath)
    }

    private func prepare(
        _ items: [LibraryMediaItem], sort: MediaLibrarySort = MediaLibrarySort(),
        previous: PreparedMediaLibraryItems? = nil,
        previousSort: MediaLibrarySort = MediaLibrarySort()
    ) async throws -> PreparedMediaLibrarySnapshot {
        try await preparer.prepare(
            MediaLibrarySnapshot(roots: [], items: items),
            requestedSourcePaths: [rootURL.path], sort: sort,
            previousLibrary: previous, previousSort: previous == nil ? nil : previousSort
        )
    }

    private func assertReusedOrdering(
        _ result: PreparedMediaLibraryItems, _ previous: PreparedMediaLibraryItems,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.orderingContext?.storageIdentityForTesting,
                       previous.orderingContext?.storageIdentityForTesting, file: file, line: line)
    }

    private func assertRebuiltOrdering(
        _ result: PreparedMediaLibraryItems, _ previous: PreparedMediaLibraryItems,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(result.orderingContext, file: file, line: line)
        XCTAssertNotEqual(result.orderingContext?.storageIdentityForTesting,
                          previous.orderingContext?.storageIdentityForTesting, file: file, line: line)
    }

    private func identity(_ value: UInt8) -> MediaFileIdentity {
        MediaFileIdentity(volumeIdentifier: Data([1]), fileIdentifier: Data([value]))
    }

    private func item(
        _ path: String, name: String, size: Int64 = 1,
        created: Double? = nil, modified: Double? = nil,
        identity: MediaFileIdentity? = nil, root: URL? = nil
    ) -> LibraryMediaItem {
        let root = root ?? rootURL
        return LibraryMediaItem(
            rootURL: root, rootName: "Synthetic", url: root.appendingPathComponent(path),
            displayName: name, relativePath: path,
            relativeDirectory: (path as NSString).deletingLastPathComponent,
            creationDate: created.map(Date.init(timeIntervalSince1970:)),
            modificationDate: modified.map(Date.init(timeIntervalSince1970:)),
            fileSize: size, fileIdentity: identity
        )
    }
}
