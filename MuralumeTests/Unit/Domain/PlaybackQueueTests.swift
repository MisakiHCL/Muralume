import XCTest
@testable import Muralume

final class PlaybackQueueTests: XCTestCase {
    func testEmptyQueueHasNoCurrentItemAndNavigationIsSafe() {
        var queue = PlaybackQueue<Int>(items: [])

        XCTAssertNil(queue.currentItem)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.roundNumber, 0)
        XCTAssertNil(queue.currentRoundPosition)
        XCTAssertNil(queue.moveToNext())
        XCTAssertNil(queue.moveToPrevious())
    }

    func testOrderedQueueStartsAtRequestedItemAndWrapsInSnapshotOrder() {
        var queue = PlaybackQueue(items: ["a", "b", "c"], startingAt: "b")

        XCTAssertEqual(queue.currentItem, "b")
        XCTAssertEqual(queue.currentRoundPosition, 2)
        XCTAssertEqual(queue.moveToNext(), "c")
        XCTAssertEqual(queue.currentRoundPosition, 3)
        XCTAssertTrue(queue.isAtEndOfRound)
        XCTAssertEqual(queue.moveToNext(), "a")
        XCTAssertEqual(queue.roundNumber, 2)
        XCTAssertEqual(queue.currentRoundPosition, 1)
        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.currentRoundPosition, 2)
    }

    func testShuffledRoundContainsEveryItemExactlyOnce() throws {
        let items = Array(1...8)
        var randomSource = SeededRandomNumberGenerator(seed: 42)
        var queue = PlaybackQueue(
            items: items,
            startingAt: 4,
            order: .shuffled,
            using: &randomSource
        )

        var playedItems = [try XCTUnwrap(queue.currentItem)]
        for expectedPosition in 2...items.count {
            playedItems.append(try XCTUnwrap(queue.moveToNext(using: &randomSource)))
            XCTAssertEqual(queue.currentRoundPosition, expectedPosition)
        }

        XCTAssertEqual(playedItems.first, 4)
        XCTAssertEqual(Set(playedItems), Set(items))
        XCTAssertEqual(playedItems.count, Set(playedItems).count)
        XCTAssertTrue(queue.isAtEndOfRound)
    }

    func testNewShuffledRoundAvoidsRepeatingPreviousRoundLastItem() {
        let items = Array(1...6)
        var randomSource = SeededRandomNumberGenerator(seed: 7)
        var queue = PlaybackQueue(
            items: items,
            order: .shuffled,
            using: &randomSource
        )

        for _ in 1..<items.count {
            queue.moveToNext(using: &randomSource)
        }
        let previousRoundLastItem = queue.currentItem

        let nextRoundFirstItem = queue.moveToNext(using: &randomSource)

        XCTAssertNotEqual(nextRoundFirstItem, previousRoundLastItem)
        XCTAssertEqual(queue.roundNumber, 2)
    }

    func testPreviousAndNextFollowNavigationHistoryWithoutResampling() throws {
        var randomSource = SeededRandomNumberGenerator(seed: 99)
        var queue = PlaybackQueue(
            items: ["a", "b", "c", "d"],
            order: .shuffled,
            using: &randomSource
        )
        let firstItem = try XCTUnwrap(queue.currentItem)
        let secondItem = try XCTUnwrap(queue.moveToNext(using: &randomSource))
        let thirdItem = try XCTUnwrap(queue.moveToNext(using: &randomSource))

        XCTAssertEqual(queue.moveToPrevious(), secondItem)
        XCTAssertEqual(queue.currentRoundPosition, 2)
        XCTAssertEqual(queue.moveToPrevious(), firstItem)
        XCTAssertEqual(queue.currentRoundPosition, 1)
        XCTAssertEqual(queue.moveToNext(using: &randomSource), secondItem)
        XCTAssertEqual(queue.currentRoundPosition, 2)
        XCTAssertEqual(queue.moveToNext(using: &randomSource), thirdItem)
        XCTAssertEqual(queue.currentRoundPosition, 3)
    }

    func testPreviousAndForwardRestoreRoundAndPositionAcrossBoundary() {
        var queue = PlaybackQueue(items: ["a", "b"])

        XCTAssertEqual(queue.currentItem, "a")
        XCTAssertEqual(queue.roundNumber, 1)
        XCTAssertEqual(queue.currentRoundPosition, 1)

        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.roundNumber, 1)
        XCTAssertEqual(queue.currentRoundPosition, 2)

        XCTAssertEqual(queue.moveToNext(), "a")
        XCTAssertEqual(queue.roundNumber, 2)
        XCTAssertEqual(queue.currentRoundPosition, 1)

        XCTAssertEqual(queue.moveToPrevious(), "b")
        XCTAssertEqual(queue.roundNumber, 1)
        XCTAssertEqual(queue.currentRoundPosition, 2)

        XCTAssertEqual(queue.moveToNext(), "a")
        XCTAssertEqual(queue.roundNumber, 2)
        XCTAssertEqual(queue.currentRoundPosition, 1)
        XCTAssertEqual(queue.history, ["a", "b"])
    }

    func testChangingOrderKeepsCurrentItemAndHistoryStable() {
        var randomSource = SeededRandomNumberGenerator(seed: 123)
        var queue = PlaybackQueue(items: [1, 2, 3, 4, 5])
        queue.moveToNext(using: &randomSource)
        let currentItem = queue.currentItem
        let history = queue.history
        let roundNumber = queue.roundNumber
        let currentRoundPosition = queue.currentRoundPosition

        queue.setOrder(.shuffled, using: &randomSource)

        XCTAssertEqual(queue.currentItem, currentItem)
        XCTAssertEqual(queue.history, history)
        XCTAssertEqual(queue.roundNumber, roundNumber)
        XCTAssertEqual(queue.currentRoundPosition, currentRoundPosition)
        XCTAssertEqual(queue.order, .shuffled)

        queue.setOrder(.ordered, using: &randomSource)

        XCTAssertEqual(queue.currentItem, currentItem)
        XCTAssertEqual(queue.history, history)
        XCTAssertEqual(queue.roundNumber, roundNumber)
        XCTAssertEqual(queue.currentRoundPosition, currentRoundPosition)
        XCTAssertEqual(queue.order, .ordered)
        XCTAssertEqual(queue.moveToNext(using: &randomSource), 3)
    }

    func testEqualSeedsProduceEqualShuffledNavigation() {
        var firstRandomSource = SeededRandomNumberGenerator(seed: 2026)
        var secondRandomSource = SeededRandomNumberGenerator(seed: 2026)
        var firstQueue = PlaybackQueue(
            items: Array(1...10),
            order: .shuffled,
            using: &firstRandomSource
        )
        var secondQueue = PlaybackQueue(
            items: Array(1...10),
            order: .shuffled,
            using: &secondRandomSource
        )

        let firstSequence = sequence(
            from: &firstQueue,
            count: 20,
            using: &firstRandomSource
        )
        let secondSequence = sequence(
            from: &secondQueue,
            count: 20,
            using: &secondRandomSource
        )

        XCTAssertEqual(firstSequence, secondSequence)
    }

    func testDuplicateItemsAreRemovedWhilePreservingFirstOccurrenceOrder() {
        var queue = PlaybackQueue(items: ["a", "b", "a", "c", "b"])

        XCTAssertEqual(queue.items, ["a", "b", "c"])
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.currentItem, "a")
        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.moveToNext(), "c")
    }

    func testLongRunningLoopKeepsNewestHistoryInNavigationOrder() throws {
        var queue = PlaybackQueue(items: [1, 2, 3])
        var visitedItems = [try XCTUnwrap(queue.currentItem)]

        for _ in 0..<1_000 {
            visitedItems.append(try XCTUnwrap(queue.moveToNext()))
        }

        let expectedHistory = Array(visitedItems.dropLast().suffix(64))
        XCTAssertEqual(queue.history, expectedHistory)

        for expectedItem in expectedHistory.reversed() {
            XCTAssertEqual(queue.moveToPrevious(), expectedItem)
        }
        XCTAssertFalse(queue.canMoveToPrevious)
    }

    private func sequence<Item: Hashable & Sendable>(
        from queue: inout PlaybackQueue<Item>,
        count: Int,
        using randomSource: inout SeededRandomNumberGenerator
    ) -> [Item] {
        guard let currentItem = queue.currentItem, count > 0 else {
            return []
        }

        var items = [currentItem]
        for _ in 1..<count {
            if let item = queue.moveToNext(using: &randomSource) {
                items.append(item)
            }
        }
        return items
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
