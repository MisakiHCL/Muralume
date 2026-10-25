import Foundation

enum MediaLibraryPerformancePolicy {
    /// Tiny libraries are cheaper to sort synchronously than to schedule on
    /// the cooperative executor. Larger libraries must not block AppKit.
    static let backgroundSortMinimumItemCount = 512
}

/// This value belongs to one immutable prepared library, not a global cache.
/// Reuse requires both the same ordering policy and the same locale snapshot.
struct PreparedMediaLibraryOrdering: Sendable {
    let sort: MediaLibrarySort
    let locale: Locale
#if DEBUG
    let storageIdentityForTesting = UUID()
#endif

    func matches(sort: MediaLibrarySort, locale: Locale) -> Bool {
        self.sort == sort && self.locale == locale
    }
}

struct PreparedMediaLibraryItems: Sendable {
    let items: [LibraryMediaItem]
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let resolutionIndex: MediaReferenceResolutionIndex
    let rootURLsByPath: [String: URL]
    let temporaryPlaybackSnapshot: TemporaryPlaybackLibrarySnapshot
    let orderingContext: PreparedMediaLibraryOrdering?
    let preparedQueueItems: PreparedPlaybackQueueItems<LibraryMediaItem.ID>

    init(
        items: [LibraryMediaItem],
        itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        resolutionIndex: MediaReferenceResolutionIndex? = nil,
        rootURLsByPath: [String: URL]? = nil,
        temporaryPlaybackSnapshot: TemporaryPlaybackLibrarySnapshot? = nil,
        orderingContext: PreparedMediaLibraryOrdering? = nil,
        preparedQueueItems: PreparedPlaybackQueueItems<LibraryMediaItem.ID>? = nil
    ) {
        self.items = items
        self.itemsByID = itemsByID
        self.orderingContext = orderingContext
        self.preparedQueueItems = preparedQueueItems
            ?? PreparedPlaybackQueueItems(items: items.map(\.id))
        self.resolutionIndex = resolutionIndex
            ?? MediaReferenceResolutionIndex(itemsByID: itemsByID)
        if let rootURLsByPath {
            self.rootURLsByPath = rootURLsByPath
        } else {
            var roots: [String: URL] = [:]
            for item in itemsByID.values where roots[item.id.rootPath] == nil {
                roots[item.id.rootPath] = item.rootURL
            }
            self.rootURLsByPath = roots
        }
        self.temporaryPlaybackSnapshot = temporaryPlaybackSnapshot
            ?? TemporaryPlaybackLibrarySnapshot(
                items: items, itemsByID: itemsByID,
                rootURLsByPath: self.rootURLsByPath
            )
    }
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

    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort,
        previousLibrary: PreparedMediaLibraryItems?,
        previousSort: MediaLibrarySort?
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

    func sort(
        _ library: PreparedMediaLibraryItems,
        using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) async throws -> PreparedMediaLibraryQueueReconciliation

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        resolutionIndex: MediaReferenceResolutionIndex
    ) async throws -> PreparedMediaLibraryQueueReconciliation
}

extension MediaLibrarySnapshotPreparing {
    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort,
        previousLibrary: PreparedMediaLibraryItems?,
        previousSort: MediaLibrarySort?
    ) async throws -> PreparedMediaLibrarySnapshot {
        try await prepare(
            snapshot, requestedSourcePaths: requestedSourcePaths, sort: sort
        )
    }

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        resolutionIndex: MediaReferenceResolutionIndex
    ) async throws -> PreparedMediaLibraryQueueReconciliation {
        try await reconcileQueue(
            snapshot: snapshot, queueItemsByID: queueItemsByID,
            availableItemsByID: availableItemsByID
        )
    }

    func sort(
        _ library: PreparedMediaLibraryItems,
        using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try await self.sort(library.items, using: sort)
    }
}

struct DefaultMediaLibrarySnapshotPreparer:
    MediaLibrarySnapshotPreparing {
    func sort(
        _ library: PreparedMediaLibraryItems,
        using sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibraryItems {
        try Task.checkCancellation()
        let context = PreparedMediaLibraryOrdering(sort: sort, locale: .current)
        let sortedItems = try sort.sortedCancellable(library.items)
        try Task.checkCancellation()
        return PreparedMediaLibraryItems(
            items: sortedItems,
            itemsByID: library.itemsByID,
            resolutionIndex: library.resolutionIndex,
            rootURLsByPath: library.rootURLsByPath,
            temporaryPlaybackSnapshot: library.temporaryPlaybackSnapshot
                .reordered(items: sortedItems),
            orderingContext: context.matches(sort: sort, locale: .current)
                ? context : nil
        )
    }

    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort
    ) async throws -> PreparedMediaLibrarySnapshot {
        try await prepare(
            snapshot, requestedSourcePaths: requestedSourcePaths, sort: sort,
            previousLibrary: nil, previousSort: nil
        )
    }

    func prepare(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        sort: MediaLibrarySort,
        previousLibrary: PreparedMediaLibraryItems?,
        previousSort: MediaLibrarySort?
    ) async throws -> PreparedMediaLibrarySnapshot {
        try Task.checkCancellation()

        let roots = snapshot.roots.filter {
            requestedSourcePaths.contains($0.id.standardizedPath)
        }
        let library = try prepareItems(
            snapshot.items.lazy.filter {
                requestedSourcePaths.contains($0.id.rootPath)
            },
            sort: sort,
            previousLibrary: previousSort == sort ? previousLibrary : nil,
            minimumCapacity: snapshot.items.count
        )

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

        return try prepareItems(
            [items, candidates].joined(), sort: sort,
            minimumCapacity: items.count + candidates.count
        )
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

        let resolutionIndex = MediaReferenceResolutionIndex(
            items: Array(availableItemsByID.values)
        )
        return try await reconcileQueue(
            snapshot: snapshot, queueItemsByID: queueItemsByID,
            availableItemsByID: availableItemsByID,
            resolutionIndex: resolutionIndex
        )
    }

    func reconcileQueue(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        resolutionIndex: MediaReferenceResolutionIndex
    ) async throws -> PreparedMediaLibraryQueueReconciliation {
        try Task.checkCancellation()
        if let exactItems = try exactQueueItems(
            snapshot: snapshot, queuedItems: queueItemsByID,
            availableItems: availableItemsByID
        ) {
            return PreparedMediaLibraryQueueReconciliation(
                queueItemsByID: exactItems, requiresQueueReplacement: false,
                replacementQueue: nil, currentItemID: snapshot.currentItem
            )
        }
        let resolution = resolutionIndex.resolveQueuedItems(queueItemsByID)

        let remappedSnapshot = remappedQueueSnapshot(
            snapshot,
            using: resolution.resolvedItemsByQueuedID
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
            queueItemsByID: resolution.canonicalItemsByID,
            requiresQueueReplacement: requiresQueueReplacement,
            replacementQueue: replacementQueue,
            currentItemID: remappedSnapshot.currentItem
        )
    }

    private func prepareItems<Items: Sequence>(
        _ items: Items,
        sort: MediaLibrarySort,
        previousLibrary: PreparedMediaLibraryItems? = nil,
        minimumCapacity: Int = 0
    ) throws -> PreparedMediaLibraryItems where Items.Element == LibraryMediaItem {
        try Task.checkCancellation()
        var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        var orderedIDs: [LibraryMediaItem.ID] = []
        let capacity = max(minimumCapacity, items.underestimatedCount)
        itemsByID.reserveCapacity(capacity)
        orderedIDs.reserveCapacity(capacity)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if itemsByID.updateValue(item, forKey: item.id) == nil {
                orderedIDs.append(item.id)
            }
        }
        try Task.checkCancellation()
        if let previousLibrary,
           let reused = try reusingOrder(
               from: previousLibrary, itemsByID: itemsByID, sort: sort
           ) {
            return reused
        }
        // Dictionary iteration discarded the scanner's existing ordered runs.
        // Keep first-seen positions while resolving duplicate IDs to the last
        // value, then let the unchanged comparator sort those runs adaptively.
        var orderedItems: [LibraryMediaItem] = []
        orderedItems.reserveCapacity(orderedIDs.count)
        for (index, id) in orderedIDs.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if let item = itemsByID[id] { orderedItems.append(item) }
        }
        return try prepareItemsByID(itemsByID, orderedItems: orderedItems, sort: sort)
    }

    private func reusingOrder(
        from library: PreparedMediaLibraryItems,
        itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        sort: MediaLibrarySort
    ) throws -> PreparedMediaLibraryItems? {
        guard let context = library.orderingContext,
              context.matches(sort: sort, locale: .current),
              library.items.count == itemsByID.count else { return nil }
        var updatedItems: [LibraryMediaItem] = []
        updatedItems.reserveCapacity(library.items.count)
        var unchanged = true
        for (index, previous) in library.items.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let updated = itemsByID[previous.id],
                  sort.hasSameOrderingValues(previous, updated) else { return nil }
            unchanged = unchanged && previous == updated
            updatedItems.append(updated)
        }
        try Task.checkCancellation()
        // A locale transition during the validation must not publish the old
        // locale's order with a context that would authorize future reuse.
        guard context.matches(sort: sort, locale: .current) else { return nil }
        if unchanged, try dictionaryKeyRepresentationsMatch(
            library.itemsByID, itemsByID
        ) { return library }
        return PreparedMediaLibraryItems(
            items: updatedItems, itemsByID: itemsByID,
            orderingContext: context,
            preparedQueueItems: library.preparedQueueItems
        )
    }

    private func dictionaryKeyRepresentationsMatch(
        _ lhs: [LibraryMediaItem.ID: LibraryMediaItem],
        _ rhs: [LibraryMediaItem.ID: LibraryMediaItem]
    ) throws -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (index, key) in lhs.keys.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let rhsIndex = rhs.index(forKey: key) else { return false }
            let rhsKey = rhs[rhsIndex].key
            guard key.rootPath == rhsKey.rootPath,
                  key.relativePath == rhsKey.relativePath else { return false }
        }
        return true
    }

    private func prepareItemsByID(
        _ itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        orderedItems: [LibraryMediaItem],
        sort: MediaLibrarySort
    ) throws -> PreparedMediaLibraryItems {
        try Task.checkCancellation()
        let context = PreparedMediaLibraryOrdering(sort: sort, locale: .current)
        var sortedItems = orderedItems
        try sort.sortInPlaceCancellable(&sortedItems)
        try Task.checkCancellation()
        return PreparedMediaLibraryItems(
            items: sortedItems,
            itemsByID: itemsByID,
            orderingContext: context.matches(sort: sort, locale: .current)
                ? context : nil
        )
    }

    private func exactQueueItems(
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        queuedItems: [LibraryMediaItem.ID: LibraryMediaItem],
        availableItems: [LibraryMediaItem.ID: LibraryMediaItem]
    ) throws -> [LibraryMediaItem.ID: LibraryMediaItem]? {
        var refreshed: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        refreshed.reserveCapacity(queuedItems.count)
        for (index, entry) in queuedItems.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let item = availableItems[entry.key],
                  item.id.rootPath == entry.key.rootPath,
                  item.id.relativePath == entry.key.relativePath else { return nil }
            refreshed[item.id] = item
        }
        var checkedCount = 0
        func representationMatches(_ id: LibraryMediaItem.ID) throws -> Bool {
            if checkedCount.isMultiple(of: 256) { try Task.checkCancellation() }
            checkedCount &+= 1
            guard let item = refreshed[id] else { return true }
            return id.rootPath == item.id.rootPath
                && id.relativePath == item.id.relativePath
        }
        guard try representationMatches(snapshot.currentItem) else { return nil }
        for ids in [snapshot.items, snapshot.remainingItems] {
            for id in ids where try !representationMatches(id) { return nil }
        }
        for locations in [snapshot.history, snapshot.forwardHistory] {
            for location in locations where try !representationMatches(location.item) {
                return nil
            }
        }
        try Task.checkCancellation()
        return refreshed
    }

    private func remappedQueueSnapshot(
        _ snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        using resolvedItemsByQueuedID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ]
    ) -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        func canonicalID(
            _ id: LibraryMediaItem.ID
        ) -> LibraryMediaItem.ID {
            resolvedItemsByQueuedID[id]?.id ?? id
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
