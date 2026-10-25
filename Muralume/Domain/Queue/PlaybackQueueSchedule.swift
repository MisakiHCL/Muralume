/// A round keeps its immutable item order and lookup index across value copies.
/// Manual selections remove positions through a persistent sparse bitmap rather
/// than shifting the array or copying a mutable membership dictionary.
struct PlaybackQueueSchedule<Item: Hashable & Sendable>: Sendable {
    private let preparedItems: PreparedPlaybackQueueItems<Item>
    private var removals: PlaybackQueueRemovedPositions?
    private var physicalIndex: Int
    private(set) var consumedCount: Int

    init(items: [Item], consumedCount: Int = 0) {
        self.init(
            preparedItems: PreparedPlaybackQueueItems(items: items),
            consumedCount: consumedCount
        )
    }

    init(
        preparedItems: PreparedPlaybackQueueItems<Item>,
        consumedCount: Int = 0
    ) {
        self.preparedItems = preparedItems
        physicalIndex = consumedCount
        self.consumedCount = consumedCount
    }

    var pendingCount: Int {
        preparedItems.items.count - (removals?.count ?? 0) - consumedCount
    }

    var nextItem: Item? {
        nextPhysicalIndex.map { preparedItems.items[$0] }
    }

#if DEBUG
    var storageIdentityForTesting: UInt {
        preparedItems.items.withUnsafeBufferPointer {
            $0.baseAddress.map { UInt(bitPattern: $0) } ?? 0
        }
    }
#endif

    mutating func takeNext() -> Item? {
        guard let index = nextPhysicalIndex else { return nil }
        physicalIndex = index + 1
        consumedCount += 1
        return preparedItems.items[index]
    }

    mutating func remove(_ item: Item) {
        guard let index = preparedItems.index(of: item),
              removals?.contains(index, width: bitmapWidth) != true else { return }
        removals = PlaybackQueueRemovedPositions.inserting(
            index, width: bitmapWidth, into: removals
        )
        if index < physicalIndex { consumedCount -= 1 }
    }

    mutating func replacePending(with pendingItems: [Item]) {
        let consumed = consumedCount
        let retained = Array(items.prefix(consumed))
        self = Self(items: retained + pendingItems, consumedCount: consumed)
    }

    func pendingItems(limit: Int = .max) -> [Item] {
        let count = min(max(limit, 0), pendingCount)
        guard count > 0 else { return [] }
        if removals == nil {
            return Array(preparedItems.items[physicalIndex...].prefix(count))
        }
        var copy = self
        var result: [Item] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            if let item = copy.takeNext() { result.append(item) }
        }
        return result
    }

    /// Structural edits and persistence use the original compact array format.
    /// Append contiguous surviving slices so materialization stays linear.
    var items: [Item] {
        guard let removals else { return preparedItems.items }
        let original = preparedItems.items
        var result: [Item] = []
        result.reserveCapacity(original.count - removals.count)
        var sliceStart = 0
        removals.forEachPosition { index in
            result.append(contentsOf: original[sliceStart..<index])
            sliceStart = index + 1
        }
        result.append(contentsOf: original[sliceStart...])
        return result
    }

    private var bitmapWidth: Int {
        var width = UInt64.bitWidth
        while width < preparedItems.items.count { width *= 2 }
        return width
    }

    private var nextPhysicalIndex: Int? {
        guard pendingCount > 0 else { return nil }
        return removals?.firstPresent(
            atOrAfter: physicalIndex, lowerBound: 0, width: bitmapWidth
        ) ?? physicalIndex
    }
}

/// Immutable nodes share untouched branches between queue copies. A selection
/// copies at most log2(roundSize / 64) branches and one 64-position leaf.
private final class PlaybackQueueRemovedPositions: Sendable {
    let count: Int
    private let lowerBound: Int
    private let bits: UInt64
    private let left: PlaybackQueueRemovedPositions?
    private let right: PlaybackQueueRemovedPositions?

    private init(
        lowerBound: Int, bits: UInt64 = 0,
        left: PlaybackQueueRemovedPositions? = nil,
        right: PlaybackQueueRemovedPositions? = nil
    ) {
        self.lowerBound = lowerBound
        self.bits = bits
        self.left = left
        self.right = right
        count = bits.nonzeroBitCount + (left?.count ?? 0) + (right?.count ?? 0)
    }

    static func inserting(
        _ position: Int, lowerBound: Int = 0, width: Int,
        into node: PlaybackQueueRemovedPositions?
    ) -> PlaybackQueueRemovedPositions {
        guard width > UInt64.bitWidth else {
            return .init(
                lowerBound: lowerBound,
                bits: (node?.bits ?? 0) | (1 << (position - lowerBound))
            )
        }
        let halfWidth = width / 2
        let middle = lowerBound + halfWidth
        if position < middle {
            return .init(
                lowerBound: lowerBound,
                left: inserting(position, lowerBound: lowerBound, width: halfWidth, into: node?.left),
                right: node?.right
            )
        }
        return .init(
            lowerBound: lowerBound,
            left: node?.left,
            right: inserting(position, lowerBound: middle, width: halfWidth, into: node?.right)
        )
    }

    func contains(_ position: Int, width: Int) -> Bool {
        guard width > UInt64.bitWidth else {
            return bits & (1 << (position - lowerBound)) != 0
        }
        let halfWidth = width / 2
        let node = position < lowerBound + halfWidth ? left : right
        return node?.contains(position, width: halfWidth) ?? false
    }

    func firstPresent(atOrAfter position: Int, lowerBound: Int, width: Int) -> Int? {
        guard position < lowerBound + width, count < width else { return nil }
        guard width > UInt64.bitWidth else {
            let offset = max(position - lowerBound, 0)
            let available = ~bits & (UInt64.max << offset)
            guard available != 0 else { return nil }
            return lowerBound + available.trailingZeroBitCount
        }
        let halfWidth = width / 2
        let middle = lowerBound + halfWidth
        if position < middle {
            if let left {
                if let result = left.firstPresent(
                    atOrAfter: position, lowerBound: lowerBound, width: halfWidth
                ) { return result }
            } else { return max(position, lowerBound) }
        }
        return right?.firstPresent(
            atOrAfter: position, lowerBound: middle, width: halfWidth
        ) ?? (right == nil ? max(position, middle) : nil)
    }

    func forEachPosition(_ body: (Int) -> Void) {
        if bits != 0 {
            var remaining = bits
            while remaining != 0 {
                body(lowerBound + remaining.trailingZeroBitCount)
                remaining &= remaining - 1
            }
        } else {
            left?.forEachPosition(body)
            right?.forEachPosition(body)
        }
    }
}
