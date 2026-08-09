import Foundation

enum MediaLibraryPerformancePolicy {
    /// Tiny libraries are cheaper to sort synchronously than to schedule on
    /// the cooperative executor. Larger libraries must not block AppKit.
    static let backgroundSortMinimumItemCount = 512
}

struct PreparedMediaLibraryItems: Sendable {
    let items: [LibraryMediaItem]
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let itemIDs: Set<LibraryMediaItem.ID>
}

struct PreparedMediaLibrarySnapshot: Sendable {
    let roots: [MediaLibraryRoot]
    let library: PreparedMediaLibraryItems
    let incompleteRootPaths: Set<String>
}

struct PreparedMediaLibraryQueueReconciliation: Sendable {
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let requiresQueueReplacement: Bool
    let replacementQueue: PlaybackQueue<LibraryMediaItem.ID>?
    let currentItemID: LibraryMediaItem.ID?
}

protocol MediaLibrarySnapshotPreparing: Sendable {
    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibrarySnapshot

    func merge(
        _ candidates: [LibraryMediaItem],
        into items: [LibraryMediaItem],
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems

    func sort(
        _ items: [LibraryMediaItem],
        using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) async throws -> PreparedMediaLibraryQueueReconciliation
}

struct DefaultMediaLibrarySnapshotPreparer:
    MediaLibrarySnapshotPreparing {
    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibrarySnapshot {
        try Task.checkCancellation()

        let roots = snapshot.roots.filter {
            requestedSourcePaths.contains($0.id.standardizedPath)
        }
        let filteredItems = snapshot.items.filter {
            requestedSourcePaths.contains($0.id.rootPath)
        }
        let library = try prepareItems(filteredItems, sort: sort)

        return PreparedMediaLibrarySnapshot(
            roots: roots,
            library: library,
            incompleteRootPaths: snapshot.incompleteRootPaths
                .intersection(requestedSourcePaths)
        )
    }

    func merge(
        _ candidates: [LibraryMediaItem],
        into items: [LibraryMediaItem],
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try Task.checkCancellation()

        var itemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        for candidate in candidates {
            itemsByID[candidate.id] = candidate
        }
        return try prepareItemsByID(itemsByID, sort: sort)
    }

    func sort(
        _ items: [LibraryMediaItem],
        using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try prepareItems(items, sort: sort)
    }

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) async throws -> PreparedMediaLibraryQueueReconciliation {
        try Task.checkCancellation()

        var reconciledItemsByID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ] = [:]
        reconciledItemsByID.reserveCapacity(queueItemsByID.count)
        for (queuedItemID, queuedItem) in queueItemsByID {
            let item = availableItemsByID[queuedItemID] ?? queuedItem
            reconciledItemsByID[item.id] = item
        }

        let remappedSnapshot = remappedQueueSnapshot(
            snapshot,
            using: availableItemsByID
        )
        try Task.checkCancellation()
        let requiresQueueReplacement = !queueRepresentationsMatch(
            remappedSnapshot,
            snapshot
        )
        let replacementQueue = requiresQueueReplacement
            ? PlaybackQueue(snapshot: remappedSnapshot)
            : nil
        try Task.checkCancellation()

        return PreparedMediaLibraryQueueReconciliation(
            queueItemsByID: reconciledItemsByID,
            requiresQueueReplacement: requiresQueueReplacement,
            replacementQueue: replacementQueue,
            currentItemID: remappedSnapshot.currentItem
        )
    }

    private func prepareItems(
        _ items: [LibraryMediaItem],
        sort: MediaLibrarySort
    ) throws -> PreparedMediaLibraryItems {
        let itemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        return try prepareItemsByID(itemsByID, sort: sort)
    }

    private func prepareItemsByID(
        _ itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        sort: MediaLibrarySort
    ) throws -> PreparedMediaLibraryItems {
        try Task.checkCancellation()
        let sortedItems = sort.sorted(Array(itemsByID.values))
        try Task.checkCancellation()
        return PreparedMediaLibraryItems(
            items: sortedItems,
            itemsByID: itemsByID,
            itemIDs: Set(itemsByID.keys)
        )
    }

    private func remappedQueueSnapshot(
        _ snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        using availableItemsByID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ]
    ) -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        func canonicalID(
            _ id: LibraryMediaItem.ID
        ) -> LibraryMediaItem.ID {
            availableItemsByID[id]?.id ?? id
        }
        func remap(
            _ location: PlaybackQueueSnapshotLocation<LibraryMediaItem.ID>
        ) -> PlaybackQueueSnapshotLocation<LibraryMediaItem.ID> {
            PlaybackQueueSnapshotLocation(
                item: canonicalID(location.item),
                roundNumber: location.roundNumber,
                position: location.position
            )
        }

        return PlaybackQueueSnapshot(
            items: snapshot.items.map(canonicalID),
            order: snapshot.order,
            currentItem: canonicalID(snapshot.currentItem),
            roundNumber: snapshot.roundNumber,
            currentRoundPosition: snapshot.currentRoundPosition,
            remainingItems: snapshot.remainingItems.map(canonicalID),
            remainingIndex: snapshot.remainingIndex,
            history: snapshot.history.map(remap),
            forwardHistory: snapshot.forwardHistory.map(remap)
        )
    }

    private func queueRepresentationsMatch(
        _ lhs: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        _ rhs: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    ) -> Bool {
        guard idsMatch(lhs.items, rhs.items),
              lhs.order == rhs.order,
              idsMatch(lhs.currentItem, rhs.currentItem),
              lhs.roundNumber == rhs.roundNumber,
              lhs.currentRoundPosition == rhs.currentRoundPosition,
              idsMatch(lhs.remainingItems, rhs.remainingItems),
              lhs.remainingIndex == rhs.remainingIndex,
              locationsMatch(lhs.history, rhs.history),
              locationsMatch(lhs.forwardHistory, rhs.forwardHistory) else {
            return false
        }
        return true
    }

    private func idsMatch(
        _ lhs: [LibraryMediaItem.ID],
        _ rhs: [LibraryMediaItem.ID]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(idsMatch)
    }

    private func idsMatch(
        _ lhs: LibraryMediaItem.ID,
        _ rhs: LibraryMediaItem.ID
    ) -> Bool {
        lhs.rootPath == rhs.rootPath
            && lhs.relativePath == rhs.relativePath
    }

    private func locationsMatch(
        _ lhs: [PlaybackQueueSnapshotLocation<LibraryMediaItem.ID>],
        _ rhs: [PlaybackQueueSnapshotLocation<LibraryMediaItem.ID>]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { lhsLocation, rhsLocation in
            idsMatch(lhsLocation.item, rhsLocation.item)
                && lhsLocation.roundNumber == rhsLocation.roundNumber
                && lhsLocation.position == rhsLocation.position
        }
    }
}
