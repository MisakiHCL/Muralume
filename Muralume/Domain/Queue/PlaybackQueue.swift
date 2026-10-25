enum PlaybackOrder: String, CaseIterable, Codable, Sendable {
    case ordered
    case shuffled
}

enum PlaybackQueueSelectionHistoryBehavior: Equatable, Sendable {
    case recordCurrent
    case skipCurrent
}

enum PlaybackQueuePendingOrderPolicy: Equatable, Sendable {
    case preserve
    case authoritative
}

enum PlaybackQueuePolicy {
    static let minimumHistoryCapacity = 64

    /// Keeps JSON recovery bounded while remaining above the 10,000-item
    /// performance fixture used by the current in-memory library.
    static let maximumPersistedItemCount = 50_000
    static let maximumPersistedHistoryEntryCount = 50_000
}

struct PlaybackQueue<Item: Hashable & Sendable>: Sendable {
    private var membership: PreparedPlaybackQueueItems<Item>
    var items: [Item] { membership.items }
    private(set) var order: PlaybackOrder
    private(set) var currentItem: Item?
    private(set) var roundNumber: Int
    private(set) var currentRoundPosition: Int?

    var history: [Item] {
        historyBuffer.elements.map(\.item)
    }

    var upNextCount: Int {
        forwardHistory.count + schedule.pendingCount
    }

    var upNextItems: [Item] {
        upNextItems(limit: .max)
    }

    func recentHistoryItems(limit: Int) -> [Item] {
        historyBuffer.suffixElements(maximumCount: limit).map(\.item)
    }

    func upNextItems(limit: Int) -> [Item] {
        guard limit > 0 else {
            return []
        }
        let resultCount = min(limit, upNextCount)
        var result: [Item] = []
        result.reserveCapacity(resultCount)

        for location in forwardHistory.reversed().prefix(resultCount) {
            result.append(location.item)
        }
        let remainingCapacity = resultCount - result.count
        if remainingCapacity > 0 {
            result.append(
                contentsOf: schedule.pendingItems(limit: remainingCapacity)
            )
        }
        return result
    }

    private var schedule = PlaybackQueueSchedule<Item>(items: [])
    private var remainingItems: [Item] { schedule.items }
    private var remainingIndex: Int { schedule.consumedCount }
    private var historyBuffer: PlaybackQueueHistoryBuffer<PlaybackQueueLocation<Item>>
    private var forwardHistory: [PlaybackQueueLocation<Item>]

    var count: Int {
        items.count
    }

    var isEmpty: Bool {
        currentItem == nil
    }

    /// Manual navigation requires another item; automatic progression may
    /// still wrap a single-item queue when the current playback mode allows it.
    var canMoveToNext: Bool {
        items.count > 1
    }

    var canMoveToPrevious: Bool {
        items.count > 1 && !historyBuffer.isEmpty
    }

    var isAtEndOfRound: Bool {
        currentItem != nil
            && forwardHistory.isEmpty
            && schedule.pendingCount == 0
    }

    var nextItemWithoutAdvancing: Item? {
        if let nextLocation = forwardHistory.last {
            return nextLocation.item
        }
        if let next = schedule.nextItem { return next }
        guard order == .ordered else {
            return nil
        }
        return items.first
    }

    var previousItemWithoutAdvancing: Item? {
        historyBuffer.last?.item
    }

#if DEBUG
    var historyStorageIdentityForTesting: UInt {
        historyBuffer.storageIdentityForTesting
    }

    var historyCapacityForTesting: Int { historyBuffer.capacity }
    var roundStorageIdentityForTesting: UInt { schedule.storageIdentityForTesting }
#endif

    init(
        items: [Item],
        startingAt requestedItem: Item? = nil,
        order: PlaybackOrder = .ordered
    ) {
        var randomSource = SystemRandomNumberGenerator()
        self.init(
            items: items,
            startingAt: requestedItem,
            order: order,
            using: &randomSource
        )
    }

    init<RandomSource: RandomNumberGenerator>(
        items: [Item],
        startingAt requestedItem: Item? = nil,
        order: PlaybackOrder = .ordered,
        using randomSource: inout RandomSource
    ) {
        let preparedItems = PreparedPlaybackQueueItems(items: items)
        self.init(
            preparedItems: preparedItems,
            requestedItem: requestedItem,
            requestedIndex: requestedItem.flatMap(preparedItems.index(of:)),
            order: order,
            using: &randomSource
        )
    }

    init(
        preparedItems: PreparedPlaybackQueueItems<Item>,
        startingAt requestedItem: Item? = nil,
        order: PlaybackOrder = .ordered
    ) {
        var randomSource = SystemRandomNumberGenerator()
        self.init(
            preparedItems: preparedItems,
            startingAt: requestedItem,
            order: order,
            using: &randomSource
        )
    }

    init<RandomSource: RandomNumberGenerator>(
        preparedItems: PreparedPlaybackQueueItems<Item>,
        startingAt requestedItem: Item? = nil,
        order: PlaybackOrder = .ordered,
        using randomSource: inout RandomSource
    ) {
        self.init(
            preparedItems: preparedItems,
            requestedItem: requestedItem,
            requestedIndex: requestedItem.flatMap(preparedItems.index(of:)),
            order: order,
            using: &randomSource
        )
    }

    private init<RandomSource: RandomNumberGenerator>(
        preparedItems: PreparedPlaybackQueueItems<Item>,
        requestedItem: Item?,
        requestedIndex: Int?,
        order: PlaybackOrder,
        using randomSource: inout RandomSource
    ) {
        let uniqueItems = preparedItems.items
        let historyCapacity = max(
            uniqueItems.count,
            PlaybackQueuePolicy.minimumHistoryCapacity
        )

        membership = preparedItems
        self.order = order
        historyBuffer = PlaybackQueueHistoryBuffer(capacity: historyCapacity)
        forwardHistory = []
        roundNumber = uniqueItems.isEmpty ? 0 : 1

        guard !uniqueItems.isEmpty else {
            currentItem = nil
            currentRoundPosition = nil
            return
        }

        switch order {
        case .ordered:
            let startingIndex = requestedIndex ?? 0
            currentItem = uniqueItems[startingIndex]
            currentRoundPosition = startingIndex + 1
            schedule = PlaybackQueueSchedule(
                preparedItems: preparedItems, consumedCount: startingIndex + 1
            )

        case .shuffled:
            if let requestedItem, requestedIndex != nil {
                currentItem = requestedItem
                currentRoundPosition = 1
                var shuffled = uniqueItems.filter { $0 != requestedItem }
                shuffled.shuffle(using: &randomSource)
                schedule = PlaybackQueueSchedule(items: shuffled)
            } else {
                var shuffled = uniqueItems
                shuffled.shuffle(using: &randomSource)
                currentItem = shuffled[0]
                currentRoundPosition = 1
                schedule = PlaybackQueueSchedule(items: shuffled, consumedCount: 1)
            }
        }
    }

    mutating func setOrder(_ order: PlaybackOrder) {
        var randomSource = SystemRandomNumberGenerator()
        setOrder(order, using: &randomSource)
    }

    mutating func setOrder<RandomSource: RandomNumberGenerator>(
        _ order: PlaybackOrder,
        using randomSource: inout RandomSource
    ) {
        guard self.order != order else {
            return
        }

        self.order = order
        var pendingItems = schedule.pendingItems()

        switch order {
        case .ordered:
            pendingItems.sort {
                (membership.index(of: $0) ?? .max) < (membership.index(of: $1) ?? .max)
            }

        case .shuffled:
            pendingItems.shuffle(using: &randomSource)
        }
        schedule = PlaybackQueueSchedule(items: pendingItems)
    }

    mutating func reshufflePendingItems() {
        var randomSource = SystemRandomNumberGenerator()
        reshufflePendingItems(using: &randomSource)
    }

    mutating func reshufflePendingItems<
        RandomSource: RandomNumberGenerator
    >(
        using randomSource: inout RandomSource
    ) {
        guard order == .shuffled else {
            return
        }

        var pendingItems = schedule.pendingItems()
        pendingItems.shuffle(using: &randomSource)
        schedule.replacePending(with: pendingItems)
    }

    @discardableResult
    mutating func moveToNext() -> Item? {
        var randomSource = SystemRandomNumberGenerator()
        return moveToNext(using: &randomSource)
    }

    @discardableResult
    mutating func moveToNext<RandomSource: RandomNumberGenerator>(
        using randomSource: inout RandomSource
    ) -> Item? {
        guard let currentLocation else {
            return nil
        }

        if let nextLocation = forwardHistory.popLast() {
            recordInHistory(currentLocation)
            restore(nextLocation)
            return nextLocation.item
        }

        if let nextItem = schedule.takeNext() {
            recordInHistory(currentLocation)
            self.currentItem = nextItem
            currentRoundPosition = min(
                currentLocation.position + 1,
                items.count
            )
            return nextItem
        }

        recordInHistory(currentLocation)
        roundNumber += 1

        var nextRound = items
        if order == .shuffled {
            nextRound.shuffle(using: &randomSource)
            Self.avoidRepeatedBoundary(in: &nextRound, after: currentLocation.item)
        }

        let nextItem = nextRound[0]
        self.currentItem = nextItem
        currentRoundPosition = 1
        schedule = order == .ordered
            ? PlaybackQueueSchedule(preparedItems: membership, consumedCount: 1)
            : PlaybackQueueSchedule(items: nextRound, consumedCount: 1)
        return nextItem
    }

    @discardableResult
    mutating func moveToPrevious() -> Item? {
        guard let currentLocation, let previousLocation = historyBuffer.popLast() else {
            return currentItem
        }

        forwardHistory.append(currentLocation)
        restore(previousLocation)
        return previousLocation.item
    }

    /// Starts a new navigation branch at an item already owned by the queue.
    /// Back history is retained, while redo history is discarded. Callers
    /// that just replaced an invalid current item may skip that transition
    /// item so a synchronization fallback is not recorded as playback.
    @discardableResult
    mutating func select(
        _ item: Item,
        historyBehavior: PlaybackQueueSelectionHistoryBehavior = .recordCurrent
    ) -> Item? {
        guard let currentLocation, membership.index(of: item) != nil else {
            return nil
        }

        if currentLocation.item != item,
           historyBehavior == .recordCurrent {
            recordInHistory(currentLocation)
        }
        forwardHistory.removeAll()

        schedule.remove(item)

        currentItem = item
        let pendingItemCount = schedule.pendingCount
        currentRoundPosition = max(1, items.count - pendingItemCount)
        return item
    }

    @discardableResult
    mutating func synchronizeItems(_ synchronizedItems: [Item]) -> Bool {
        var randomSource = SystemRandomNumberGenerator()
        return synchronizeItems(
            synchronizedItems,
            pendingOrderPolicy: .preserve,
            using: &randomSource
        )
    }

    @discardableResult
    mutating func synchronizeItems(
        _ synchronizedItems: [Item],
        pendingOrderPolicy: PlaybackQueuePendingOrderPolicy
    ) -> Bool {
        var randomSource = SystemRandomNumberGenerator()
        return synchronizeItems(
            synchronizedItems,
            pendingOrderPolicy: pendingOrderPolicy,
            using: &randomSource
        )
    }

    /// Reconciles queue membership without rebuilding navigation state.
    /// Existing pending items keep their relative order in both playback modes.
    /// Returns whether the authoritative membership or item order changed.
    @discardableResult
    mutating func synchronizeItems<RandomSource: RandomNumberGenerator>(
        _ synchronizedItems: [Item],
        pendingOrderPolicy: PlaybackQueuePendingOrderPolicy = .preserve,
        using randomSource: inout RandomSource
    ) -> Bool {
        synchronizeUniqueItems(
            PreparedPlaybackQueueItems(items: synchronizedItems),
            pendingOrderPolicy: pendingOrderPolicy,
            using: &randomSource
        )
    }

    @discardableResult
    mutating func synchronizeItems(
        _ preparedItems: PreparedPlaybackQueueItems<Item>,
        pendingOrderPolicy: PlaybackQueuePendingOrderPolicy = .preserve
    ) -> Bool {
        var randomSource = SystemRandomNumberGenerator()
        return synchronizeItems(
            preparedItems,
            pendingOrderPolicy: pendingOrderPolicy,
            using: &randomSource
        )
    }

    @discardableResult
    mutating func synchronizeItems<RandomSource: RandomNumberGenerator>(
        _ preparedItems: PreparedPlaybackQueueItems<Item>,
        pendingOrderPolicy: PlaybackQueuePendingOrderPolicy = .preserve,
        using randomSource: inout RandomSource
    ) -> Bool {
        synchronizeUniqueItems(
            preparedItems,
            pendingOrderPolicy: pendingOrderPolicy,
            using: &randomSource
        )
    }

    private mutating func synchronizeUniqueItems<
        RandomSource: RandomNumberGenerator
    >(
        _ preparedItems: PreparedPlaybackQueueItems<Item>,
        pendingOrderPolicy: PlaybackQueuePendingOrderPolicy,
        using randomSource: inout RandomSource
    ) -> Bool {
        let uniqueItems = preparedItems.items
        let needsAuthoritativePendingReorder =
            pendingOrderPolicy == .authoritative
                && order == .ordered
                && authoritativePendingItems(from: uniqueItems)
                    != schedule.pendingItems()
        guard uniqueItems != items || needsAuthoritativePendingReorder else {
            return false
        }

        let previousItemSet = Set(items)
        let synchronizedItemSet = Set(uniqueItems)
        let removedItems = previousItemSet.subtracting(synchronizedItemSet)
        let addedItems = uniqueItems.filter {
            !previousItemSet.contains($0)
        }
        let retainedOrder = order

        if !removedItems.isEmpty {
            _ = remove(removedItems, using: &randomSource)
        }

        guard !uniqueItems.isEmpty else {
            return true
        }
        guard !isEmpty else {
            self = PlaybackQueue(
                items: uniqueItems,
                order: retainedOrder,
                using: &randomSource
            )
            return true
        }

        membership = preparedItems
        historyBuffer.resizeIfNeeded(
            max(
                uniqueItems.count,
                PlaybackQueuePolicy.minimumHistoryCapacity
            )
        )

        switch order {
        case .ordered:
            insertOrderedAdditions(
                addedItems,
                authoritativeItems: uniqueItems
            )
            if pendingOrderPolicy == .authoritative {
                schedule.replacePending(with: authoritativePendingItems(from: uniqueItems))
            }
        case .shuffled:
            insertShuffledAdditions(
                addedItems,
                using: &randomSource
            )
        }
        return true
    }

    private func authoritativePendingItems(
        from authoritativeItems: [Item]
    ) -> [Item] {
        let pendingItemSet = Set(schedule.pendingItems())
        return authoritativeItems.filter(pendingItemSet.contains)
    }

    @discardableResult
    mutating func remove(_ removedItems: Set<Item>) -> Item? {
        var randomSource = SystemRandomNumberGenerator()
        return remove(removedItems, using: &randomSource)
    }

    @discardableResult
    mutating func remove<RandomSource: RandomNumberGenerator>(
        _ removedItems: Set<Item>,
        using randomSource: inout RandomSource
    ) -> Item? {
        let activeRemovals = removedItems.intersection(Set(items))
        guard !activeRemovals.isEmpty else {
            return currentItem
        }

        let previousCurrentItem = currentItem
        let previousPosition = currentRoundPosition
        let currentRoundNumber = roundNumber
        let currentRemainingItems = remainingItems
        let remainingIndicesByItem = Dictionary(
            uniqueKeysWithValues: currentRemainingItems.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        var navigationLocations = historyBuffer.elements
        navigationLocations.append(contentsOf: forwardHistory)
        if let currentLocation {
            navigationLocations.append(currentLocation)
        }
        let removedLocations = navigationLocations.filter {
            activeRemovals.contains($0.item)
        }
        var removedPositionsByRound = Dictionary(
            grouping: removedLocations,
            by: \.roundNumber
        ).mapValues { locations in
            locations.map(\.position)
        }
        let knownRemovedCurrentRoundItems = Set(
            removedLocations.lazy
                .filter { $0.roundNumber == currentRoundNumber }
                .map(\.item)
        )
        let remainingPositionOffset = navigationLocations.lazy
            .filter { $0.roundNumber == currentRoundNumber }
            .compactMap { location -> Int? in
                guard let index = remainingIndicesByItem[location.item] else {
                    return nil
                }
                return location.position - index
            }
            .first
            ?? max(
                1,
                (previousPosition ?? 0) + 1 - remainingIndex
            )
        for (index, item) in currentRemainingItems.enumerated()
        where activeRemovals.contains(item)
            && !knownRemovedCurrentRoundItems.contains(item) {
            removedPositionsByRound[currentRoundNumber, default: []]
                .append(index + remainingPositionOffset)
        }
        // Preserve repeated historical positions: each occurrence contributed
        // to the previous linear count. Sorting enables the same count with a
        // binary search for every retained location.
        removedPositionsByRound = removedPositionsByRound.mapValues {
            $0.sorted()
        }
        let removedBeforeCurrentCount = currentRemainingItems[..<remainingIndex]
            .filter {
                $0 != previousCurrentItem && activeRemovals.contains($0)
            }
            .count
        let adjustedPosition = max(
            1,
            (previousPosition ?? 1) - removedBeforeCurrentCount
        )
        let consumedItems = currentRemainingItems[..<remainingIndex].filter {
            !activeRemovals.contains($0)
        }
        let pendingItems = currentRemainingItems[remainingIndex...].filter {
            !activeRemovals.contains($0)
        }

        membership = PreparedPlaybackQueueItems(items: items.filter {
            !activeRemovals.contains($0)
        })
        historyBuffer.removeAll {
            activeRemovals.contains($0.item)
        }
        forwardHistory.removeAll {
            activeRemovals.contains($0.item)
        }
        historyBuffer.mapElements {
            Self.adjustedLocation(
                $0,
                removedPositionsByRound: removedPositionsByRound
            )
        }
        historyBuffer.resizeIfNeeded(
            max(items.count, PlaybackQueuePolicy.minimumHistoryCapacity)
        )
        forwardHistory = forwardHistory.map {
            Self.adjustedLocation(
                $0,
                removedPositionsByRound: removedPositionsByRound
            )
        }

        guard !items.isEmpty else {
            currentItem = nil
            currentRoundPosition = nil
            roundNumber = 0
            schedule = PlaybackQueueSchedule(items: [])
            forwardHistory.removeAll()
            return nil
        }

        schedule = PlaybackQueueSchedule(
            items: consumedItems + pendingItems, consumedCount: consumedItems.count
        )

        guard let previousCurrentItem,
              activeRemovals.contains(previousCurrentItem) else {
            currentRoundPosition = min(
                adjustedPosition,
                maximumCurrentPositionPreservingPendingItems
            )
            return currentItem
        }

        if let nextLocation = forwardHistory.popLast() {
            restore(nextLocation)
            currentRoundPosition = min(
                currentRoundPosition ?? 1,
                maximumCurrentPositionPreservingPendingItems
            )
            return currentItem
        }

        if let nextItem = schedule.takeNext() {
            currentItem = nextItem
            currentRoundPosition = min(
                adjustedPosition,
                maximumCurrentPositionPreservingPendingItems
            )
            return currentItem
        }

        roundNumber = max(roundNumber + 1, 1)
        var nextRound = items
        if order == .shuffled {
            nextRound.shuffle(using: &randomSource)
        }
        currentItem = nextRound[0]
        currentRoundPosition = 1
        schedule = order == .ordered
            ? PlaybackQueueSchedule(preparedItems: membership, consumedCount: 1)
            : PlaybackQueueSchedule(items: nextRound, consumedCount: 1)
        return currentItem
    }

    private static func adjustedLocation(
        _ location: PlaybackQueueLocation<Item>,
        removedPositionsByRound: [Int: [Int]]
    ) -> PlaybackQueueLocation<Item> {
        let removedPositions = removedPositionsByRound[
            location.roundNumber,
            default: []
        ]
        var lowerBound = 0
        var upperBound = removedPositions.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if removedPositions[middle] < location.position {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return PlaybackQueueLocation(
            item: location.item,
            roundNumber: location.roundNumber,
            position: max(
                1,
                location.position
                    - lowerBound
            )
        )
    }

    private var maximumCurrentPositionPreservingPendingItems: Int {
        guard forwardHistory.isEmpty else {
            return items.count
        }
        let pendingItemCount = schedule.pendingCount
        return max(1, items.count - pendingItemCount)
    }

    private mutating func insertOrderedAdditions(
        _ addedItems: [Item],
        authoritativeItems: [Item]
    ) {
        guard let currentItem else {
            return
        }

        let authoritativePositions = Dictionary(
            uniqueKeysWithValues: authoritativeItems.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        guard let currentAuthoritativePosition = authoritativePositions[
            currentItem
        ] else {
            return
        }

        let positionedAdditions: [(item: Item, position: Int)] = addedItems
            .compactMap { addedItem in
                guard let position = authoritativePositions[addedItem],
                      position > currentAuthoritativePosition else {
                    return nil
                }
                return (addedItem, position)
            }
        let pendingItems = schedule.pendingItems()
        var mergedPendingItems: [Item] = []
        mergedPendingItems.reserveCapacity(
            pendingItems.count + positionedAdditions.count
        )
        var additionIndex = 0

        for pendingItem in pendingItems {
            let pendingPosition = authoritativePositions[
                pendingItem,
                default: .max
            ]
            while additionIndex < positionedAdditions.count,
                  positionedAdditions[additionIndex].position
                    < pendingPosition {
                mergedPendingItems.append(
                    positionedAdditions[additionIndex].item
                )
                additionIndex += 1
            }
            mergedPendingItems.append(pendingItem)
        }
        if additionIndex < positionedAdditions.count {
            mergedPendingItems.append(
                contentsOf: positionedAdditions[additionIndex...].map(\.item)
            )
        }
        schedule.replacePending(with: mergedPendingItems)
    }

    private mutating func insertShuffledAdditions<
        RandomSource: RandomNumberGenerator
    >(
        _ addedItems: [Item],
        using randomSource: inout RandomSource
    ) {
        let pendingItems = schedule.pendingItems()
        var randomizedAdditions = addedItems
        randomizedAdditions.shuffle(using: &randomSource)
        var additionsByGap = Array(
            repeating: [Item](),
            count: pendingItems.count + 1
        )
        for addedItem in randomizedAdditions {
            let gapIndex = Int.random(
                in: 0...pendingItems.count,
                using: &randomSource
            )
            additionsByGap[gapIndex].append(addedItem)
        }

        var mergedPendingItems: [Item] = []
        mergedPendingItems.reserveCapacity(
            pendingItems.count + randomizedAdditions.count
        )
        for gapIndex in additionsByGap.indices {
            mergedPendingItems.append(contentsOf: additionsByGap[gapIndex])
            if gapIndex < pendingItems.count {
                mergedPendingItems.append(pendingItems[gapIndex])
            }
        }
        schedule.replacePending(with: mergedPendingItems)
    }

    private var currentLocation: PlaybackQueueLocation<Item>? {
        guard let currentItem, let currentRoundPosition else {
            return nil
        }
        return PlaybackQueueLocation(
            item: currentItem,
            roundNumber: roundNumber,
            position: currentRoundPosition
        )
    }

    private mutating func recordInHistory(_ location: PlaybackQueueLocation<Item>) {
        historyBuffer.append(location)
    }

    private mutating func restore(_ location: PlaybackQueueLocation<Item>) {
        currentItem = location.item
        roundNumber = location.roundNumber
        currentRoundPosition = min(location.position, items.count)
    }

    private static func avoidRepeatedBoundary(in items: inout [Item], after previousItem: Item) {
        guard items.count > 1, items.first == previousItem else {
            return
        }

        guard let replacementIndex = items.dropFirst().firstIndex(where: { $0 != previousItem }) else {
            return
        }

        items.swapAt(items.startIndex, replacementIndex)
    }
}

extension PlaybackQueue where Item: Codable {
    func makeSnapshot() -> PlaybackQueueSnapshot<Item>? {
        guard let currentItem, let currentRoundPosition else {
            return nil
        }

        return PlaybackQueueSnapshot(
            items: items,
            order: order,
            currentItem: currentItem,
            roundNumber: roundNumber,
            currentRoundPosition: currentRoundPosition,
            remainingItems: remainingItems,
            remainingIndex: remainingIndex,
            history: historyBuffer.elements.map {
                PlaybackQueueSnapshotLocation(
                    item: $0.item,
                    roundNumber: $0.roundNumber,
                    position: $0.position
                )
            },
            forwardHistory: forwardHistory.map {
                PlaybackQueueSnapshotLocation(
                    item: $0.item,
                    roundNumber: $0.roundNumber,
                    position: $0.position
                )
            }
        )
    }

    init?(snapshot: PlaybackQueueSnapshot<Item>) {
        let preparedItems = PreparedPlaybackQueueItems(items: snapshot.items)
        let uniqueItems = preparedItems.items
        let itemSet = Set(uniqueItems)
        guard snapshot.isWithinPersistenceLimits,
              !uniqueItems.isEmpty,
              uniqueItems.count == snapshot.items.count,
              itemSet.contains(snapshot.currentItem),
              snapshot.roundNumber > 0,
              (1...uniqueItems.count).contains(
                  snapshot.currentRoundPosition
              ),
              snapshot.remainingIndex >= 0,
              snapshot.remainingIndex <= snapshot.remainingItems.count,
              Set(snapshot.remainingItems).count
                  == snapshot.remainingItems.count,
              snapshot.remainingItems.allSatisfy(itemSet.contains),
              Self.locationsAreValid(snapshot.history, items: itemSet),
              Self.locationsAreValid(
                  snapshot.forwardHistory,
                  items: itemSet
              ) else {
            return nil
        }

        membership = preparedItems
        order = snapshot.order
        currentItem = snapshot.currentItem
        roundNumber = snapshot.roundNumber
        currentRoundPosition = snapshot.currentRoundPosition
        schedule = PlaybackQueueSchedule(
            items: snapshot.remainingItems, consumedCount: snapshot.remainingIndex
        )
        historyBuffer = PlaybackQueueHistoryBuffer(
            capacity: max(
                uniqueItems.count,
                PlaybackQueuePolicy.minimumHistoryCapacity
            )
        )
        for location in snapshot.history {
            historyBuffer.append(
                PlaybackQueueLocation(
                    item: location.item,
                    roundNumber: location.roundNumber,
                    position: location.position
                )
            )
        }
        forwardHistory = snapshot.forwardHistory.map {
            PlaybackQueueLocation(
                item: $0.item,
                roundNumber: $0.roundNumber,
                position: $0.position
            )
        }
    }

    private static func locationsAreValid(
        _ locations: [PlaybackQueueSnapshotLocation<Item>],
        items: Set<Item>
    ) -> Bool {
        locations.allSatisfy {
            items.contains($0.item)
                && $0.roundNumber > 0
                && $0.position > 0
        }
    }
}
