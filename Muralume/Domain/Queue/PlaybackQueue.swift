enum PlaybackOrder: String, CaseIterable, Codable, Sendable {
    case ordered
    case shuffled
}

enum PlaybackQueuePolicy {
    static let minimumHistoryCapacity = 64

    /// Keeps JSON recovery bounded while remaining above the 10,000-item
    /// performance fixture used by the current in-memory library.
    static let maximumPersistedItemCount = 50_000
    static let maximumPersistedHistoryEntryCount = 50_000
}

private struct PlaybackQueueLocation<Item: Sendable>: Sendable {
    let item: Item
    let roundNumber: Int
    let position: Int
}

struct PlaybackQueueSnapshotLocation<Item>: Codable, Equatable, Sendable
where Item: Codable & Hashable & Sendable {
    let item: Item
    let roundNumber: Int
    let position: Int
}

enum PlaybackQueueSnapshotCodingError: Error, Equatable, Sendable {
    case limitExceeded(itemCount: Int, historyEntryCount: Int)
}

struct PlaybackQueueSnapshot<Item>: Codable, Equatable, Sendable
where Item: Codable & Hashable & Sendable {
    let items: [Item]
    let order: PlaybackOrder
    let currentItem: Item
    let roundNumber: Int
    let currentRoundPosition: Int
    let remainingItems: [Item]
    let remainingIndex: Int
    let history: [PlaybackQueueSnapshotLocation<Item>]
    let forwardHistory: [PlaybackQueueSnapshotLocation<Item>]

    private enum CodingKeys: String, CodingKey {
        case items
        case order
        case currentItem
        case roundNumber
        case currentRoundPosition
        case remainingItems
        case remainingIndex
        case history
        case forwardHistory
    }

    init(
        items: [Item],
        order: PlaybackOrder,
        currentItem: Item,
        roundNumber: Int,
        currentRoundPosition: Int,
        remainingItems: [Item],
        remainingIndex: Int,
        history: [PlaybackQueueSnapshotLocation<Item>],
        forwardHistory: [PlaybackQueueSnapshotLocation<Item>]
    ) {
        self.items = items
        self.order = order
        self.currentItem = currentItem
        self.roundNumber = roundNumber
        self.currentRoundPosition = currentRoundPosition
        self.remainingItems = remainingItems
        self.remainingIndex = remainingIndex
        self.history = history
        self.forwardHistory = forwardHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems: [Item] = try Self.decodeBoundedArray(
            forKey: .items,
            maximumCount: PlaybackQueuePolicy.maximumPersistedItemCount,
            from: container,
            limitError: { count in
                .limitExceeded(itemCount: count, historyEntryCount: 0)
            }
        )
        let decodedOrder = try container.decode(
            PlaybackOrder.self,
            forKey: .order
        )
        let decodedCurrentItem = try container.decode(
            Item.self,
            forKey: .currentItem
        )
        let decodedRoundNumber = try container.decode(
            Int.self,
            forKey: .roundNumber
        )
        let decodedCurrentRoundPosition = try container.decode(
            Int.self,
            forKey: .currentRoundPosition
        )
        let decodedRemainingItems: [Item] = try Self.decodeBoundedArray(
            forKey: .remainingItems,
            maximumCount: PlaybackQueuePolicy.maximumPersistedItemCount,
            from: container,
            limitError: { count in
                .limitExceeded(
                    itemCount: max(decodedItems.count, count),
                    historyEntryCount: 0
                )
            }
        )
        let decodedRemainingIndex = try container.decode(
            Int.self,
            forKey: .remainingIndex
        )
        let decodedHistory: [PlaybackQueueSnapshotLocation<Item>] =
            try Self.decodeBoundedArray(
                forKey: .history,
                maximumCount:
                    PlaybackQueuePolicy.maximumPersistedHistoryEntryCount,
                from: container,
                limitError: { count in
                    .limitExceeded(
                        itemCount: max(
                            decodedItems.count,
                            decodedRemainingItems.count
                        ),
                        historyEntryCount: count
                    )
                }
            )
        let decodedForwardHistory: [PlaybackQueueSnapshotLocation<Item>] =
            try Self.decodeBoundedArray(
                forKey: .forwardHistory,
                maximumCount:
                    PlaybackQueuePolicy.maximumPersistedHistoryEntryCount
                        - decodedHistory.count,
                from: container,
                limitError: { count in
                    .limitExceeded(
                        itemCount: max(
                            decodedItems.count,
                            decodedRemainingItems.count
                        ),
                        historyEntryCount: decodedHistory.count + count
                    )
                }
            )

        items = decodedItems
        order = decodedOrder
        currentItem = decodedCurrentItem
        roundNumber = decodedRoundNumber
        currentRoundPosition = decodedCurrentRoundPosition
        remainingItems = decodedRemainingItems
        remainingIndex = decodedRemainingIndex
        history = decodedHistory
        forwardHistory = decodedForwardHistory
    }

    var isWithinPersistenceLimits: Bool {
        guard items.count <= PlaybackQueuePolicy.maximumPersistedItemCount,
              remainingItems.count
                <= PlaybackQueuePolicy.maximumPersistedItemCount,
              history.count
                <= PlaybackQueuePolicy.maximumPersistedHistoryEntryCount else {
            return false
        }
        return forwardHistory.count
            <= PlaybackQueuePolicy.maximumPersistedHistoryEntryCount
                - history.count
    }

    var persistenceItemCount: Int {
        max(items.count, remainingItems.count)
    }

    var persistenceHistoryEntryCount: Int {
        history.count + forwardHistory.count
    }

    private static func decodeBoundedArray<Element: Decodable>(
        forKey key: CodingKeys,
        maximumCount: Int,
        from container: KeyedDecodingContainer<CodingKeys>,
        limitError: (Int) -> PlaybackQueueSnapshotCodingError
    ) throws -> [Element] {
        var valuesContainer = try container.nestedUnkeyedContainer(
            forKey: key
        )
        if let count = valuesContainer.count, count > maximumCount {
            throw limitError(count)
        }

        var values: [Element] = []
        values.reserveCapacity(min(valuesContainer.count ?? 0, maximumCount))
        while !valuesContainer.isAtEnd {
            guard values.count < maximumCount else {
                throw limitError(maximumCount + 1)
            }
            values.append(try valuesContainer.decode(Element.self))
        }
        return values
    }
}

private struct BoundedHistoryBuffer<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var startIndex = 0
    private(set) var count = 0

    var isEmpty: Bool {
        count == 0
    }

    var elements: [Element] {
        (0..<count).map { offset in
            guard let element = storage[storageIndex(for: offset)] else {
                preconditionFailure("History buffer storage is inconsistent")
            }
            return element
        }
    }

    var last: Element? {
        guard count > 0 else {
            return nil
        }
        return storage[storageIndex(for: count - 1)]
    }

#if DEBUG
    var storageIdentityForTesting: UInt {
        storage.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return UInt(bitPattern: baseAddress)
        }
    }
#endif

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        if count < storage.count {
            storage[storageIndex(for: count)] = element
            count += 1
            return
        }

        storage[startIndex] = element
        startIndex = (startIndex + 1) % storage.count
    }

    mutating func popLast() -> Element? {
        guard count > 0 else {
            return nil
        }

        let index = storageIndex(for: count - 1)
        let element = storage[index]
        storage[index] = nil
        count -= 1

        if count == 0 {
            startIndex = 0
        }
        return element
    }

    mutating func removeAll(
        where shouldRemove: (Element) -> Bool
    ) {
        let retainedElements = elements.filter {
            !shouldRemove($0)
        }
        replaceElements(with: retainedElements)
    }

    mutating func mapElements(
        _ transform: (Element) -> Element
    ) {
        replaceElements(with: elements.map(transform))
    }

    private mutating func replaceElements(with elements: [Element]) {
        storage = Array(repeating: nil, count: storage.count)
        startIndex = 0
        count = 0
        for element in elements {
            append(element)
        }
    }

    private func storageIndex(for offset: Int) -> Int {
        (startIndex + offset) % storage.count
    }
}

struct PlaybackQueue<Item: Hashable & Sendable>: Sendable {
    private(set) var items: [Item]
    private(set) var order: PlaybackOrder
    private(set) var currentItem: Item?
    private(set) var roundNumber: Int
    private(set) var currentRoundPosition: Int?

    var history: [Item] {
        historyBuffer.elements.map(\.item)
    }

    private var remainingItems: [Item]
    private var remainingIndex: Int
    private var historyBuffer: BoundedHistoryBuffer<PlaybackQueueLocation<Item>>
    private var forwardHistory: [PlaybackQueueLocation<Item>]

    var count: Int {
        items.count
    }

    var isEmpty: Bool {
        currentItem == nil
    }

    var canMoveToPrevious: Bool {
        !historyBuffer.isEmpty
    }

    var isAtEndOfRound: Bool {
        currentItem != nil
            && forwardHistory.isEmpty
            && remainingIndex >= remainingItems.count
    }

    var nextItemWithoutAdvancing: Item? {
        if let nextLocation = forwardHistory.last {
            return nextLocation.item
        }
        if remainingIndex < remainingItems.count {
            return remainingItems[remainingIndex]
        }
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
        let uniqueItems = Self.uniqued(items)
        let historyCapacity = max(
            uniqueItems.count,
            PlaybackQueuePolicy.minimumHistoryCapacity
        )

        self.items = uniqueItems
        self.order = order
        historyBuffer = BoundedHistoryBuffer(capacity: historyCapacity)
        forwardHistory = []
        roundNumber = uniqueItems.isEmpty ? 0 : 1

        guard !uniqueItems.isEmpty else {
            currentItem = nil
            currentRoundPosition = nil
            remainingItems = []
            remainingIndex = 0
            return
        }

        switch order {
        case .ordered:
            let startingIndex = requestedItem.flatMap(uniqueItems.firstIndex(of:)) ?? 0
            currentItem = uniqueItems[startingIndex]
            currentRoundPosition = startingIndex + 1
            remainingItems = uniqueItems
            remainingIndex = startingIndex + 1

        case .shuffled:
            if let requestedItem, uniqueItems.contains(requestedItem) {
                currentItem = requestedItem
                currentRoundPosition = 1
                remainingItems = uniqueItems.filter { $0 != requestedItem }
                remainingItems.shuffle(using: &randomSource)
                remainingIndex = 0
            } else {
                remainingItems = uniqueItems
                remainingItems.shuffle(using: &randomSource)
                currentItem = remainingItems[0]
                currentRoundPosition = 1
                remainingIndex = 1
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
        var pendingItems = Array(remainingItems[remainingIndex...])

        switch order {
        case .ordered:
            let originalPositions = Dictionary(
                uniqueKeysWithValues: items.enumerated().map { ($0.element, $0.offset) }
            )
            pendingItems.sort {
                originalPositions[$0, default: .max] < originalPositions[$1, default: .max]
            }

        case .shuffled:
            pendingItems.shuffle(using: &randomSource)
        }
        remainingItems = pendingItems
        remainingIndex = 0
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

        var pendingItems = Array(remainingItems[remainingIndex...])
        pendingItems.shuffle(using: &randomSource)
        remainingItems.replaceSubrange(
            remainingIndex...,
            with: pendingItems
        )
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

        if remainingIndex < remainingItems.count {
            recordInHistory(currentLocation)
            let nextItem = remainingItems[remainingIndex]
            remainingIndex += 1
            self.currentItem = nextItem
            currentRoundPosition = currentLocation.position + 1
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
        remainingItems = nextRound
        remainingIndex = 1
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
                guard let index = currentRemainingItems.firstIndex(
                    of: location.item
                ) else {
                    return nil
                }
                return location.position - index
            }
            .first
            ?? max(
                1,
                (previousPosition ?? 0) + 1 - remainingIndex
            )
        for (index, item) in remainingItems.enumerated()
        where activeRemovals.contains(item)
            && !knownRemovedCurrentRoundItems.contains(item) {
            removedPositionsByRound[currentRoundNumber, default: []]
                .append(index + remainingPositionOffset)
        }
        let removedBeforeCurrentCount = remainingItems[..<remainingIndex]
            .filter {
                $0 != previousCurrentItem && activeRemovals.contains($0)
            }
            .count
        let adjustedPosition = max(
            1,
            (previousPosition ?? 1) - removedBeforeCurrentCount
        )
        let consumedItems = remainingItems[..<remainingIndex].filter {
            !activeRemovals.contains($0)
        }
        let pendingItems = remainingItems[remainingIndex...].filter {
            !activeRemovals.contains($0)
        }

        items.removeAll {
            activeRemovals.contains($0)
        }
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
            remainingItems = []
            remainingIndex = 0
            forwardHistory.removeAll()
            return nil
        }

        remainingItems = consumedItems + pendingItems
        remainingIndex = consumedItems.count

        guard let previousCurrentItem,
              activeRemovals.contains(previousCurrentItem) else {
            currentRoundPosition = min(adjustedPosition, items.count)
            return currentItem
        }

        if let nextLocation = forwardHistory.popLast() {
            restore(nextLocation)
            currentRoundPosition = min(
                currentRoundPosition ?? 1,
                items.count
            )
            return currentItem
        }

        if remainingIndex < remainingItems.count {
            currentItem = remainingItems[remainingIndex]
            remainingIndex += 1
            currentRoundPosition = min(adjustedPosition, items.count)
            return currentItem
        }

        roundNumber = max(roundNumber + 1, 1)
        var nextRound = items
        if order == .shuffled {
            nextRound.shuffle(using: &randomSource)
        }
        currentItem = nextRound[0]
        currentRoundPosition = 1
        remainingItems = nextRound
        remainingIndex = 1
        return currentItem
    }

    private static func adjustedLocation(
        _ location: PlaybackQueueLocation<Item>,
        removedPositionsByRound: [Int: [Int]]
    ) -> PlaybackQueueLocation<Item> {
        let knownRemovalCount = removedPositionsByRound[
            location.roundNumber,
            default: []
        ].filter { $0 < location.position }.count

        return PlaybackQueueLocation(
            item: location.item,
            roundNumber: location.roundNumber,
            position: max(
                1,
                location.position
                    - knownRemovalCount
            )
        )
    }

    private static func uniqued(_ items: [Item]) -> [Item] {
        var seenItems: Set<Item> = []
        return items.filter { seenItems.insert($0).inserted }
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
        currentRoundPosition = location.position
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
        let uniqueItems = Self.uniqued(snapshot.items)
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

        items = uniqueItems
        order = snapshot.order
        currentItem = snapshot.currentItem
        roundNumber = snapshot.roundNumber
        currentRoundPosition = snapshot.currentRoundPosition
        remainingItems = snapshot.remainingItems
        remainingIndex = snapshot.remainingIndex
        historyBuffer = BoundedHistoryBuffer(
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
