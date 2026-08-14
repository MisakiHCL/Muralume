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

        XCTAssertTrue(queue.canMoveToNext)
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

    func testSingleItemQueueDisablesManualNavigationAcrossRounds() {
        var queue = PlaybackQueue(items: ["a"])

        XCTAssertFalse(queue.canMoveToNext)
        XCTAssertFalse(queue.canMoveToPrevious)
        XCTAssertEqual(queue.moveToNext(), "a")
        XCTAssertFalse(queue.canMoveToNext)
        XCTAssertFalse(queue.canMoveToPrevious)
    }

    func testNavigationLookaheadMatchesNextMovesWithoutChangingSnapshot()
        throws {
        var queue = PlaybackQueue(items: ["a", "b", "c"])
        let initialSnapshot = try XCTUnwrap(queue.makeSnapshot())

        XCTAssertEqual(queue.nextItemWithoutAdvancing, "b")
        XCTAssertNil(queue.previousItemWithoutAdvancing)
        XCTAssertEqual(queue.upNextItems, ["b", "c"])
        XCTAssertEqual(queue.makeSnapshot(), initialSnapshot)

        XCTAssertEqual(queue.moveToNext(), "b")
        let secondItemSnapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.nextItemWithoutAdvancing, "c")
        XCTAssertEqual(queue.previousItemWithoutAdvancing, "a")
        XCTAssertEqual(queue.upNextItems, ["c"])
        XCTAssertEqual(queue.makeSnapshot(), secondItemSnapshot)

        XCTAssertEqual(queue.moveToPrevious(), "a")
        let restoredSnapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.nextItemWithoutAdvancing, "b")
        XCTAssertNil(queue.previousItemWithoutAdvancing)
        XCTAssertEqual(queue.upNextItems, ["b", "c"])
        XCTAssertEqual(queue.makeSnapshot(), restoredSnapshot)
    }

    func testUpNextItemsFollowsForwardHistoryBeforeRemainingSchedule() {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d", "e"])
        _ = queue.moveToNext()
        _ = queue.moveToNext()
        _ = queue.moveToNext()
        _ = queue.moveToPrevious()
        _ = queue.moveToPrevious()

        XCTAssertEqual(queue.currentItem, "b")
        XCTAssertEqual(queue.upNextItems, ["c", "d", "e"])
    }

    func testBoundedQueueProjectionsAvoidMaterializingTheWholeQueue() {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d", "e"])
        _ = queue.moveToNext()
        _ = queue.moveToNext()
        _ = queue.moveToNext()
        _ = queue.moveToPrevious()

        XCTAssertEqual(queue.upNextCount, 2)
        XCTAssertEqual(queue.upNextItems(limit: 0), [])
        XCTAssertEqual(queue.upNextItems(limit: 1), ["d"])
        XCTAssertEqual(queue.upNextItems(limit: 2), ["d", "e"])
        XCTAssertEqual(queue.recentHistoryItems(limit: 1), ["b"])
        XCTAssertEqual(queue.recentHistoryItems(limit: 2), ["a", "b"])
    }

    func testLargeQueueProjectionReturnsOnlyTheRequestedWindow() {
        let itemCount = 50_000
        let windowSize = 40
        let queue = PlaybackQueue(items: Array(0..<itemCount))

        XCTAssertEqual(queue.upNextCount, itemCount - 1)
        XCTAssertEqual(
            queue.upNextItems(limit: windowSize),
            Array(1...windowSize)
        )
    }

    func testShuffledRoundBoundaryRequiresMutationToChooseNextItem() {
        var randomSource = SeededRandomNumberGenerator(seed: 42)
        var queue = PlaybackQueue(
            items: ["a", "b"],
            order: .shuffled,
            using: &randomSource
        )

        _ = queue.moveToNext(using: &randomSource)

        XCTAssertTrue(queue.isAtEndOfRound)
        XCTAssertNil(queue.nextItemWithoutAdvancing)
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

    func testColdRestoreCanReshuffleOnlyPendingRandomItems() throws {
        let snapshot = PlaybackQueueSnapshot(
            items: ["a", "b", "c", "d", "e", "f", "g"],
            order: .shuffled,
            currentItem: "c",
            roundNumber: 3,
            currentRoundPosition: 3,
            remainingItems: ["a", "b", "c", "d", "e", "f", "g"],
            remainingIndex: 4,
            history: [
                PlaybackQueueSnapshotLocation(
                    item: "a",
                    roundNumber: 3,
                    position: 1
                ),
                PlaybackQueueSnapshotLocation(
                    item: "b",
                    roundNumber: 3,
                    position: 2
                )
            ],
            forwardHistory: [
                PlaybackQueueSnapshotLocation(
                    item: "d",
                    roundNumber: 3,
                    position: 4
                )
            ]
        )
        var firstQueue = try XCTUnwrap(PlaybackQueue(snapshot: snapshot))
        var secondQueue = try XCTUnwrap(PlaybackQueue(snapshot: snapshot))
        var firstRandomSource = SeededRandomNumberGenerator(seed: 1)
        var secondRandomSource = SeededRandomNumberGenerator(seed: 1)

        firstQueue.reshufflePendingItems(using: &firstRandomSource)
        secondQueue.reshufflePendingItems(using: &secondRandomSource)

        let firstResult = try XCTUnwrap(firstQueue.makeSnapshot())
        let secondResult = try XCTUnwrap(secondQueue.makeSnapshot())
        XCTAssertEqual(firstResult.currentItem, snapshot.currentItem)
        XCTAssertEqual(firstResult.roundNumber, snapshot.roundNumber)
        XCTAssertEqual(
            firstResult.currentRoundPosition,
            snapshot.currentRoundPosition
        )
        XCTAssertEqual(firstResult.remainingIndex, snapshot.remainingIndex)
        XCTAssertEqual(firstResult.history, snapshot.history)
        XCTAssertEqual(firstResult.forwardHistory, snapshot.forwardHistory)
        XCTAssertEqual(
            Array(firstResult.remainingItems.prefix(snapshot.remainingIndex)),
            Array(snapshot.remainingItems.prefix(snapshot.remainingIndex))
        )
        XCTAssertEqual(
            Set(firstResult.remainingItems.suffix(3)),
            Set(snapshot.remainingItems.suffix(3))
        )
        XCTAssertEqual(firstResult.remainingItems, secondResult.remainingItems)
        XCTAssertNotEqual(
            Array(firstResult.remainingItems.suffix(3)),
            Array(snapshot.remainingItems.suffix(3))
        )

        var navigationRandomSource = SeededRandomNumberGenerator(seed: 99)
        XCTAssertEqual(
            firstQueue.moveToNext(using: &navigationRandomSource),
            "d"
        )
        XCTAssertEqual(firstQueue.currentRoundPosition, 4)
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

    func testSelectingItemBranchesFromCurrentQueueState() throws {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.moveToNext(), "c")
        XCTAssertEqual(queue.moveToPrevious(), "b")
#if DEBUG
        let historyStorageIdentity = queue.historyStorageIdentityForTesting
#endif

        XCTAssertEqual(queue.select("d"), "d")

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.currentItem, "d")
        XCTAssertEqual(queue.currentRoundPosition, 4)
        XCTAssertEqual(queue.history, ["a", "b"])
#if DEBUG
        XCTAssertEqual(
            queue.historyStorageIdentityForTesting,
            historyStorageIdentity
        )
#endif
        XCTAssertTrue(snapshot.forwardHistory.isEmpty)
        XCTAssertEqual(
            Array(snapshot.remainingItems[snapshot.remainingIndex...]),
            ["e"]
        )
        XCTAssertEqual(queue.upNextItems, ["e"])
        XCTAssertEqual(queue.nextItemWithoutAdvancing, "e")
        XCTAssertEqual(queue.moveToPrevious(), "b")
        XCTAssertEqual(queue.moveToNext(), "d")
    }

    func testSelectingItemCanSkipOnlyTheTransitionCurrentItem() throws {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d"])
        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.moveToNext(), "c")

        XCTAssertEqual(
            queue.select("d", historyBehavior: .skipCurrent),
            "d"
        )

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.currentItem, "d")
        XCTAssertEqual(queue.history, ["a", "b"])
        XCTAssertTrue(snapshot.forwardHistory.isEmpty)
        XCTAssertEqual(queue.moveToPrevious(), "b")
    }

    func testSelectingMissingItemLeavesQueueUnchanged() throws {
        var queue = PlaybackQueue(items: ["a", "b", "c"])
        _ = queue.moveToNext()
        let snapshot = try XCTUnwrap(queue.makeSnapshot())

        XCTAssertNil(queue.select("missing"))
        XCTAssertEqual(queue.makeSnapshot(), snapshot)
    }

    func testSynchronizingOrderedItemsInsertsOnlyNewItemsAfterCurrent() throws {
        var queue = PlaybackQueue(items: ["a", "c", "e"])
        XCTAssertEqual(queue.moveToNext(), "c")

        XCTAssertTrue(
            queue.synchronizeItems(["before", "a", "c", "d", "e", "f"])
        )

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.currentItem, "c")
        XCTAssertEqual(snapshot.items, ["before", "a", "c", "d", "e", "f"])
        XCTAssertEqual(queue.history, ["a"])
        XCTAssertEqual(
            Array(snapshot.remainingItems[snapshot.remainingIndex...]),
            ["d", "e", "f"]
        )
        XCTAssertEqual(queue.moveToNext(), "d")
        XCTAssertEqual(queue.moveToNext(), "e")
        XCTAssertEqual(queue.moveToNext(), "f")
        XCTAssertEqual(queue.moveToNext(), "before")
        XCTAssertEqual(queue.roundNumber, 2)
    }

    func testSynchronizingShuffledItemsOnlyInterleavesNewPendingItems()
        throws {
        let originalSnapshot = PlaybackQueueSnapshot(
            items: ["a", "b", "c", "d", "e"],
            order: .shuffled,
            currentItem: "b",
            roundNumber: 2,
            currentRoundPosition: 2,
            remainingItems: ["a", "b", "c", "d", "e"],
            remainingIndex: 2,
            history: [
                PlaybackQueueSnapshotLocation(
                    item: "a",
                    roundNumber: 2,
                    position: 1
                )
            ],
            forwardHistory: []
        )
        var firstQueue = try XCTUnwrap(
            PlaybackQueue(snapshot: originalSnapshot)
        )
        var secondQueue = try XCTUnwrap(
            PlaybackQueue(snapshot: originalSnapshot)
        )
        var firstRandomSource = SeededRandomNumberGenerator(seed: 77)
        var secondRandomSource = SeededRandomNumberGenerator(seed: 77)
        let synchronizedItems = ["a", "b", "c", "x", "e", "y"]

        firstQueue.synchronizeItems(
            synchronizedItems,
            using: &firstRandomSource
        )
        secondQueue.synchronizeItems(
            synchronizedItems,
            using: &secondRandomSource
        )

        let firstSnapshot = try XCTUnwrap(firstQueue.makeSnapshot())
        let secondSnapshot = try XCTUnwrap(secondQueue.makeSnapshot())
        let firstPendingItems = Array(
            firstSnapshot.remainingItems[firstSnapshot.remainingIndex...]
        )
        XCTAssertEqual(firstSnapshot.items, synchronizedItems)
        XCTAssertEqual(firstQueue.currentItem, "b")
        XCTAssertEqual(firstQueue.history, ["a"])
        XCTAssertEqual(
            firstPendingItems.filter { ["c", "e"].contains($0) },
            ["c", "e"]
        )
        XCTAssertEqual(
            Set(firstPendingItems),
            Set(["c", "e", "x", "y"])
        )
        XCTAssertEqual(firstSnapshot, secondSnapshot)
    }

    func testSynchronizingDeletionSafelyAdvancesRemovedCurrentItem() throws {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d"])
        XCTAssertEqual(queue.moveToNext(), "b")

        XCTAssertTrue(queue.synchronizeItems(["a", "c", "d", "e"]))

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        XCTAssertEqual(queue.currentItem, "c")
        XCTAssertEqual(queue.history, ["a"])
        XCTAssertEqual(snapshot.items, ["a", "c", "d", "e"])
        XCTAssertEqual(
            Array(snapshot.remainingItems[snapshot.remainingIndex...]),
            ["d", "e"]
        )
        XCTAssertEqual(queue.moveToNext(), "d")
        XCTAssertEqual(queue.moveToNext(), "e")
    }

    func testSynchronizingEquivalentMembershipReportsNoStructuralChange()
        throws {
        var queue = PlaybackQueue(items: ["a", "b", "c"])
        _ = queue.moveToNext()
        let snapshot = try XCTUnwrap(queue.makeSnapshot())

        XCTAssertFalse(queue.synchronizeItems(["a", "b", "a", "c"]))
        XCTAssertEqual(queue.makeSnapshot(), snapshot)
        XCTAssertTrue(queue.synchronizeItems(["c", "b", "a"]))
        XCTAssertEqual(queue.items, ["c", "b", "a"])
    }

    func testAuthoritativeOrderedSynchronizationReordersOnlyPendingItems()
        throws {
        var queue = PlaybackQueue(items: ["a", "b", "c", "d"])
        XCTAssertEqual(queue.moveToNext(), "b")
        let historyBefore = queue.history

        XCTAssertTrue(
            queue.synchronizeItems(
                ["d", "a", "b", "c"],
                pendingOrderPolicy: .authoritative
            )
        )

        XCTAssertEqual(queue.currentItem, "b")
        XCTAssertEqual(queue.history, historyBefore)
        XCTAssertEqual(queue.upNextItems, ["d", "c"])
        XCTAssertEqual(queue.moveToNext(), "d")
        XCTAssertEqual(queue.moveToNext(), "c")
    }

    func testAuthoritativeSynchronizationLeavesShuffledPendingOrderStable()
        throws {
        var randomSource = SeededRandomNumberGenerator(seed: 44)
        var queue = PlaybackQueue(
            items: ["a", "b", "c", "d"],
            startingAt: "b",
            order: .shuffled,
            using: &randomSource
        )
        let pendingBefore = queue.upNextItems

        XCTAssertTrue(
            queue.synchronizeItems(
                ["d", "c", "b", "a"],
                pendingOrderPolicy: .authoritative,
                using: &randomSource
            )
        )

        XCTAssertEqual(queue.currentItem, "b")
        XCTAssertEqual(queue.upNextItems, pendingBefore)
    }

    func testRemovingDeferredOrderedItemKeepsPendingPositionInBounds() throws {
        var queue = PlaybackQueue(items: ["a", "c"])
        XCTAssertEqual(queue.moveToNext(), "c")
        XCTAssertTrue(
            queue.synchronizeItems(["before", "a", "c", "d"])
        )
        XCTAssertEqual(queue.select("c"), "c")

        XCTAssertEqual(queue.remove(["before"]), "c")

        XCTAssertEqual(queue.currentRoundPosition, 2)
        XCTAssertEqual(queue.moveToNext(), "d")
        XCTAssertEqual(queue.currentRoundPosition, 3)
        XCTAssertNotNil(queue.makeSnapshot())
        XCTAssertNotNil(
            PlaybackQueue(snapshot: try XCTUnwrap(queue.makeSnapshot()))
        )
    }

    func testPendingAdvanceKeepsRecoveredPositionWithinMembershipBounds()
        throws {
        let snapshot = PlaybackQueueSnapshot(
            items: ["a", "b"],
            order: .ordered,
            currentItem: "a",
            roundNumber: 3,
            currentRoundPosition: 2,
            remainingItems: ["b"],
            remainingIndex: 0,
            history: [],
            forwardHistory: []
        )
        var queue = try XCTUnwrap(PlaybackQueue(snapshot: snapshot))

        XCTAssertEqual(queue.moveToNext(), "b")
        XCTAssertEqual(queue.currentRoundPosition, 2)
        XCTAssertNotNil(
            PlaybackQueue(snapshot: try XCTUnwrap(queue.makeSnapshot()))
        )
    }

    func testSynchronizingGrowthExpandsNavigationHistoryCapacity() {
        var queue = PlaybackQueue(items: [0])
        let synchronizedItems = Array(0..<100)

        queue.synchronizeItems(synchronizedItems)
        for _ in 1..<synchronizedItems.count {
            _ = queue.moveToNext()
        }

        XCTAssertEqual(queue.history, Array(0..<99))
    }

    func testSynchronizingCanEmptyAndLaterRepopulateQueue() {
        var queue = PlaybackQueue(items: ["a", "b"])

        XCTAssertTrue(queue.synchronizeItems([]))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.currentItem)
        XCTAssertFalse(queue.synchronizeItems([]))

        XCTAssertTrue(queue.synchronizeItems(["c", "d"]))
        XCTAssertEqual(queue.items, ["c", "d"])
        XCTAssertEqual(queue.currentItem, "c")
        XCTAssertEqual(queue.upNextItems, ["d"])
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

    func testSnapshotRoundTripPreservesRandomRoundAndNavigationHistory() throws {
        var randomSource = SeededRandomNumberGenerator(seed: 88)
        var queue = PlaybackQueue(
            items: ["a", "b", "c", "d", "e"],
            startingAt: "c",
            order: .shuffled,
            using: &randomSource
        )
        _ = queue.moveToNext(using: &randomSource)
        _ = queue.moveToNext(using: &randomSource)
        _ = queue.moveToPrevious()

        let snapshot = try XCTUnwrap(queue.makeSnapshot())
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            PlaybackQueueSnapshot<String>.self,
            from: data
        )
        var restored = try XCTUnwrap(PlaybackQueue(snapshot: decoded))

        XCTAssertEqual(restored.currentItem, queue.currentItem)
        XCTAssertEqual(restored.order, queue.order)
        XCTAssertEqual(restored.roundNumber, queue.roundNumber)
        XCTAssertEqual(
            restored.currentRoundPosition,
            queue.currentRoundPosition
        )
        XCTAssertEqual(restored.history, queue.history)

        var firstContinuationRandom = SeededRandomNumberGenerator(seed: 9)
        var secondContinuationRandom = SeededRandomNumberGenerator(seed: 9)
        XCTAssertEqual(
            sequence(
                from: &restored,
                count: 12,
                using: &firstContinuationRandom
            ),
            sequence(
                from: &queue,
                count: 12,
                using: &secondContinuationRandom
            )
        )
    }

    func testSnapshotRejectsCorruptCurrentItem() {
        let snapshot = PlaybackQueueSnapshot(
            items: ["a", "b"],
            order: .ordered,
            currentItem: "missing",
            roundNumber: 1,
            currentRoundPosition: 1,
            remainingItems: ["a", "b"],
            remainingIndex: 1,
            history: [],
            forwardHistory: []
        )

        XCTAssertNil(PlaybackQueue(snapshot: snapshot))
    }

    func testSnapshotRejectsPersistedItemCountAboveLimit() throws {
        let items = Array(
            0...PlaybackQueuePolicy.maximumPersistedItemCount
        )
        let snapshot = PlaybackQueueSnapshot(
            items: items,
            order: .ordered,
            currentItem: items[0],
            roundNumber: 1,
            currentRoundPosition: 1,
            remainingItems: [],
            remainingIndex: 0,
            history: [],
            forwardHistory: []
        )

        XCTAssertFalse(snapshot.isWithinPersistenceLimits)
        XCTAssertNil(PlaybackQueue(snapshot: snapshot))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PlaybackQueueSnapshot<Int>.self,
                from: data
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackQueueSnapshotCodingError,
                .limitExceeded(
                    itemCount:
                        PlaybackQueuePolicy.maximumPersistedItemCount + 1,
                    historyEntryCount: 0
                )
            )
        }
    }

    func testSnapshotRejectsCombinedNavigationHistoryAboveLimit() throws {
        let location = PlaybackQueueSnapshotLocation(
            item: "a",
            roundNumber: 1,
            position: 1
        )
        let snapshot = PlaybackQueueSnapshot(
            items: ["a"],
            order: .ordered,
            currentItem: "a",
            roundNumber: 1,
            currentRoundPosition: 1,
            remainingItems: ["a"],
            remainingIndex: 1,
            history: Array(
                repeating: location,
                count: PlaybackQueuePolicy.maximumPersistedHistoryEntryCount
            ),
            forwardHistory: [location]
        )

        XCTAssertFalse(snapshot.isWithinPersistenceLimits)
        XCTAssertNil(PlaybackQueue(snapshot: snapshot))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PlaybackQueueSnapshot<String>.self,
                from: data
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackQueueSnapshotCodingError,
                .limitExceeded(
                    itemCount: 1,
                    historyEntryCount:
                        PlaybackQueuePolicy
                            .maximumPersistedHistoryEntryCount + 1
                )
            )
        }
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
