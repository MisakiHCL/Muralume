import XCTest
@testable import Muralume

final class PlaybackQueuePerformanceTests: XCTestCase {
    func testManualSelectionSharesRoundStorageAndUsesBoundedLookups() {
        let counter = SelectionWorkCounter()
        let items = (0..<50_000).map { SelectionCountedItem(value: $0, counter: counter) }
        let original = PlaybackQueue(items: items)
        var selected = original
#if DEBUG
        let roundStorage = original.roundStorageIdentityForTesting
#endif
        counter.reset()

        XCTAssertEqual(selected.select(items[49_999])?.value, 49_999)
        let work = counter.reading

        // Count work rather than wall time: selecting a tail item must not scan
        // the membership or rebuild either full round index after a value copy.
        XCTAssertLessThan(work.comparisons, 64)
        XCTAssertLessThan(work.hashes, 64)
#if DEBUG
        XCTAssertEqual(selected.roundStorageIdentityForTesting, roundStorage)
#endif
        XCTAssertEqual(original.currentItem?.value, 0)
        XCTAssertEqual(original.upNextCount, 49_999)
        XCTAssertEqual(selected.upNextCount, 49_998)
        XCTAssertEqual(selected.nextItemWithoutAdvancing?.value, 1)
        XCTAssertEqual(selected.upNextItems.count, 49_998)
    }

    func testSelectionAcrossPositionBoundariesPreservesCompactSnapshotAndRedo() throws {
        var queue = PlaybackQueue(items: Array(0..<200), startingAt: 64)
        for item in [63, 64, 65, 127, 128, 199] {
            XCTAssertEqual(queue.select(item), item)
        }

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(snapshot.remainingItems, Array(0..<200).filter {
            ![63, 64, 65, 127, 128, 199].contains($0)
        })
        XCTAssertEqual(snapshot.remainingIndex, 63)
        XCTAssertEqual(queue.upNextCount, 131)
        XCTAssertEqual(queue.currentRoundPosition, 69)
        XCTAssertEqual(queue.upNextItems(limit: 3), [66, 67, 68])
        XCTAssertEqual(queue.history, [64, 63, 64, 65, 127, 128])

        var restored = try XCTUnwrap(PlaybackQueue(snapshot: snapshot))
        XCTAssertEqual(restored.makeSnapshot(), snapshot)
        for current in [128, 199, 66] {
            let actual = current == 128 ? queue.moveToPrevious() : queue.moveToNext()
            let recovered = current == 128 ? restored.moveToPrevious() : restored.moveToNext()
            XCTAssertEqual(actual, current)
            XCTAssertEqual(recovered, current)
            XCTAssertEqual(queue.makeSnapshot(), restored.makeSnapshot())
        }
    }

    func testOrderedAdvancementAndRoundWrapDoNotRebuildMembershipIndexes() {
        let counter = SelectionWorkCounter()
        let items = (0..<10_000).map { SelectionCountedItem(value: $0, counter: counter) }
        var queue = PlaybackQueue(items: items)
#if DEBUG
        let roundStorage = queue.roundStorageIdentityForTesting
#endif
        counter.reset()

        for _ in 0...items.count { _ = queue.moveToNext() }
        let work = counter.reading

        XCTAssertEqual(queue.currentItem?.value, 1)
        XCTAssertEqual(work.hashes, 0)
        XCTAssertEqual(work.comparisons, 0)
#if DEBUG
        XCTAssertEqual(queue.roundStorageIdentityForTesting, roundStorage)
#endif
    }

    func testSelectingAnEntirePendingRangeAdvancesToNextSurvivor() throws {
        var queue = PlaybackQueue(items: Array(0..<10_000))
        for item in 1..<9_000 { _ = queue.select(item) }

        XCTAssertEqual(queue.upNextCount, 1_000)
        XCTAssertEqual(queue.nextItemWithoutAdvancing, 9_000)
        XCTAssertEqual(queue.moveToNext(), 9_000)
        XCTAssertEqual(queue.upNextItems(limit: 3), [9_001, 9_002, 9_003])
        let before = queue.makeSnapshot()
        XCTAssertEqual(queue.select(9_000), 9_000)
        XCTAssertEqual(queue.makeSnapshot()?.remainingItems, before?.remainingItems.filter { $0 != 9_000 })
    }

    func testQueueCopiesKeepIndependentSelectionRemovals() {
        let original = PlaybackQueue(items: Array(0..<200))
        var first = original
        var second = original
        _ = first.select(64)
        _ = first.select(128)
        _ = second.select(65)
        _ = second.select(129)

        XCTAssertEqual(first.upNextItems, Array(1..<200).filter { $0 != 64 && $0 != 128 })
        XCTAssertEqual(second.upNextItems, Array(1..<200).filter { $0 != 65 && $0 != 129 })
        XCTAssertEqual(original.upNextItems, Array(1..<200))
    }

    func testLargeMembershipReductionReleasesHistoryAndKeepsNewestEntries() {
        var queue = PlaybackQueue(items: Array(0..<10_000))
        for _ in 0..<100 {
            _ = queue.select(1)
            _ = queue.select(0)
        }
        let retainedHistory = Array(queue.history.suffix(64))

        XCTAssertTrue(queue.synchronizeItems([0, 1]))

        XCTAssertEqual(queue.history, retainedHistory)
#if DEBUG
        XCTAssertEqual(queue.historyCapacityForTesting, 64)
#endif
        for item in retainedHistory.reversed() {
            XCTAssertEqual(queue.moveToPrevious(), item)
        }
        XCTAssertFalse(queue.canMoveToPrevious)
    }

    func testHistoryCapacityUsesHysteresisForModestReductions() {
        var queue = PlaybackQueue(items: Array(0..<1_000))
        XCTAssertTrue(queue.synchronizeItems(Array(0..<600)))
#if DEBUG
        XCTAssertEqual(queue.historyCapacityForTesting, 1_000)
#endif
        XCTAssertTrue(queue.synchronizeItems(Array(0..<200)))
#if DEBUG
        XCTAssertEqual(queue.historyCapacityForTesting, 200)
#endif
        XCTAssertTrue(queue.synchronizeItems([]))
#if DEBUG
        XCTAssertLessThan(queue.historyCapacityForTesting, 64 * 4)
#endif
    }
}

private final class SelectionWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes = 0
    private var comparisons = 0

    var reading: (hashes: Int, comparisons: Int) {
        lock.withLock { (hashes, comparisons) }
    }
    func recordHash() { lock.withLock { hashes += 1 } }
    func recordComparison() { lock.withLock { comparisons += 1 } }
    func reset() { lock.withLock { hashes = 0; comparisons = 0 } }
}

private struct SelectionCountedItem: Hashable, Sendable {
    let value: Int
    let counter: SelectionWorkCounter

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.counter.recordComparison()
        return lhs.value == rhs.value
    }
    func hash(into hasher: inout Hasher) {
        counter.recordHash()
        hasher.combine(value)
    }
}
