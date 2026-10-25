import XCTest
@testable import Muralume

final class PreparedPlaybackQueueTests: XCTestCase {
    func testPreparedMembershipKeepsFirstValuesAndPositionsAcrossDuplicates() {
        let values = [
            RepresentedPreparedItem(id: 2, representation: "first"),
            RepresentedPreparedItem(id: 1, representation: "one"),
            RepresentedPreparedItem(id: 2, representation: "duplicate"),
            RepresentedPreparedItem(id: 3, representation: "three"),
            RepresentedPreparedItem(id: 1, representation: "another duplicate")
        ]
        let prepared = PreparedPlaybackQueueItems(items: values)

        XCTAssertEqual(prepared.items.map(\.id), [2, 1, 3])
        XCTAssertEqual(prepared.items.map(\.representation), ["first", "one", "three"])
        XCTAssertEqual(prepared.index(of: values[2]), 0)
        XCTAssertEqual(prepared.index(of: values[4]), 1)
        XCTAssertEqual(prepared.index(of: values[3]), 2)
        XCTAssertNil(prepared.index(of: .init(id: 4, representation: "missing")))
    }

    func testPreparedInitializationMatchesLegacyQueueAndRandomConsumption() {
        let fixtures: [[Int]] = [[], [1], [3, 3, 3], [3, 1, 3, 2, 1], Array(0..<129)]
        for values in fixtures {
            let prepared = PreparedPlaybackQueueItems(items: values)
            for order in PlaybackOrder.allCases {
                for requested: Int? in [nil, -1, 0, 1, 3, 128] {
                    for seed: UInt64 in [0, 1, 47] {
                        var legacyRandom = PreparedQueueRandom(seed: seed)
                        var preparedRandom = legacyRandom
                        var legacy = PlaybackQueue(
                            items: values, startingAt: requested, order: order,
                            using: &legacyRandom
                        )
                        var fast = PlaybackQueue(
                            preparedItems: prepared, startingAt: requested, order: order,
                            using: &preparedRandom
                        )
                        XCTAssertEqual(fast.makeSnapshot(), legacy.makeSnapshot())
                        XCTAssertEqual(preparedRandom, legacyRandom)
                        for step in 0..<8 {
                            XCTAssertEqual(
                                fast.moveToNext(using: &preparedRandom),
                                legacy.moveToNext(using: &legacyRandom)
                            )
                            if step.isMultiple(of: 3) {
                                XCTAssertEqual(fast.moveToPrevious(), legacy.moveToPrevious())
                            }
                            XCTAssertEqual(fast.makeSnapshot(), legacy.makeSnapshot())
                            XCTAssertEqual(preparedRandom, legacyRandom)
                        }
                    }
                }
            }
        }
    }

    func testRequestedEquivalentRepresentationKeepsExistingModeSemantics() {
        let canonical = RepresentedPreparedItem(id: 1, representation: "canonical")
        let alias = RepresentedPreparedItem(id: 1, representation: "requested")
        let prepared = PreparedPlaybackQueueItems(items: [
            canonical, RepresentedPreparedItem(id: 2, representation: "other")
        ])
        let ordered = PlaybackQueue(preparedItems: prepared, startingAt: alias)
        let shuffled = PlaybackQueue(
            preparedItems: prepared, startingAt: alias, order: .shuffled
        )

        XCTAssertEqual(ordered.currentItem?.representation, "canonical")
        XCTAssertEqual(shuffled.currentItem?.representation, "requested")
        XCTAssertEqual(prepared.items.first?.representation, "canonical")
    }

    func testPreparedInitializationDoesNotRehashWholeMembershipOnUIPath() {
        let counter = PreparedQueueWorkCounter()
        let values = (0..<10_000).map { CountedPreparedItem(value: $0, counter: counter) }
        let prepared = PreparedPlaybackQueueItems(items: values)
        counter.reset()
        let withoutSelection = PlaybackQueue(preparedItems: prepared)
        let workWithoutSelection = counter.reading
        counter.reset()
        let selected = PlaybackQueue(preparedItems: prepared, startingAt: values[7_777])
        let workWithSelection = counter.reading

        XCTAssertEqual(withoutSelection.currentItem?.value, 0)
        XCTAssertEqual(selected.currentItem?.value, 7_777)
        XCTAssertEqual(workWithoutSelection.hashes, 0)
        XCTAssertLessThanOrEqual(workWithSelection.hashes, 8)
        XCTAssertLessThanOrEqual(workWithSelection.comparisons, 8)
    }

    func testPreparedSynchronizationMatchesLegacyNavigationAndRandomState() {
        let initial = [0, 1, 2, 3, 4, 5]
        let changes = [
            [0, 1, 2, 3, 4, 5], [5, 4, 3, 2, 1, 0, 0],
            [5, 2, 6, 6, 7], [], [8, 8, 9, 10], [10, 9, 8]
        ]
        for order in PlaybackOrder.allCases {
            for policy: PlaybackQueuePendingOrderPolicy in [.preserve, .authoritative] {
                var legacyRandom = PreparedQueueRandom(seed: 83)
                var fastRandom = legacyRandom
                var legacy = PlaybackQueue(
                    items: initial, startingAt: 2, order: order, using: &legacyRandom
                )
                var fast = PlaybackQueue(
                    preparedItems: PreparedPlaybackQueueItems(items: initial),
                    startingAt: 2, order: order, using: &fastRandom
                )
                for change in changes {
                    _ = legacy.moveToNext(using: &legacyRandom)
                    _ = fast.moveToNext(using: &fastRandom)
                    _ = legacy.moveToPrevious()
                    _ = fast.moveToPrevious()
                    XCTAssertEqual(
                        fast.synchronizeItems(
                            PreparedPlaybackQueueItems(items: change),
                            pendingOrderPolicy: policy, using: &fastRandom
                        ),
                        legacy.synchronizeItems(
                            change, pendingOrderPolicy: policy, using: &legacyRandom
                        )
                    )
                    XCTAssertEqual(fast.items, legacy.items)
                    XCTAssertEqual(fast.makeSnapshot(), legacy.makeSnapshot())
                    XCTAssertEqual(fastRandom, legacyRandom)
                }
            }
        }
    }

    func testUnchangedPreparedSynchronizationSkipsRepeatedDeduplication() {
        let counter = PreparedQueueWorkCounter()
        let values = (0..<10_000).map { CountedPreparedItem(value: $0, counter: counter) }
        let prepared = PreparedPlaybackQueueItems(items: values)
        var queue = PlaybackQueue(preparedItems: prepared)
        counter.reset()

        let changed = queue.synchronizeItems(prepared)
        let work = counter.reading

        XCTAssertFalse(changed)
        XCTAssertEqual(work.hashes, 0)
    }

    func testPreparedValuesAndQueuesKeepCopyOnWriteIsolation() {
        var source = [0, 1, 2, 3]
        let prepared = PreparedPlaybackQueueItems(items: source)
        let original = PlaybackQueue(preparedItems: prepared, startingAt: 1)
        let originalSnapshot = original.makeSnapshot()
        var changed = original
        source.reverse()
        source.append(4)
        _ = changed.moveToNext()
        _ = changed.select(3)
        _ = changed.synchronizeItems(PreparedPlaybackQueueItems(items: [3, 4, 5]))

        XCTAssertEqual(prepared.items, [0, 1, 2, 3])
        XCTAssertEqual(prepared.index(of: 3), 3)
        XCTAssertEqual(original.makeSnapshot(), originalSnapshot)
        XCTAssertEqual(changed.items, [3, 4, 5])
        XCTAssertEqual(source, [3, 2, 1, 0, 4])
    }

    func testPreparedQueueRetainsOriginalHistoryCapacityAndPersistenceLimit() {
        let values = Array(0..<129)
        var legacy = PlaybackQueue(items: values)
        var fast = PlaybackQueue(preparedItems: PreparedPlaybackQueueItems(items: values))
        for _ in 0..<180 {
            _ = legacy.moveToNext()
            _ = fast.moveToNext()
        }
        XCTAssertEqual(fast.history.count, values.count)
        XCTAssertEqual(fast.makeSnapshot(), legacy.makeSnapshot())

        let largeCount = PlaybackQueuePolicy.maximumPersistedItemCount + 1
        let prepared = PreparedPlaybackQueueItems(items: Array(0..<largeCount))
        var large = PlaybackQueue(preparedItems: prepared, startingAt: largeCount - 1)
        XCTAssertEqual(large.count, largeCount)
        XCTAssertEqual(large.moveToNext(), 0)
        XCTAssertEqual(large.moveToNext(), 1)
        XCTAssertEqual(large.history, [largeCount - 1, 0])
        XCTAssertEqual(large.makeSnapshot()?.isWithinPersistenceLimits, false)
    }
}

private struct PreparedQueueRandom: RandomNumberGenerator, Equatable {
    private var state: UInt64
    private var drawCount = 0

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        drawCount += 1
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct RepresentedPreparedItem: Codable, Hashable, Sendable {
    let id: Int
    let representation: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private final class PreparedQueueWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes = 0
    private var comparisons = 0

    var reading: (hashes: Int, comparisons: Int) {
        lock.withLock { (hashes, comparisons) }
    }

    func hash() { lock.withLock { hashes += 1 } }
    func compare() { lock.withLock { comparisons += 1 } }
    func reset() { lock.withLock { hashes = 0; comparisons = 0 } }
}

private struct CountedPreparedItem: Hashable, Sendable {
    let value: Int
    let counter: PreparedQueueWorkCounter

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.counter.compare()
        return lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        counter.hash()
        hasher.combine(value)
    }
}
