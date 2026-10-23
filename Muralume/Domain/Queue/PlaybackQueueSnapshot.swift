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
