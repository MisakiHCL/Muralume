import Foundation

/// Immutable input retained through publication so large replaced collections
/// can be released by the background worker after the main-actor apply ends.
struct MediaLibraryPublicationRequest: Sendable {
    let prepared: PreparedMediaLibrarySnapshot
    let oldItems: [LibraryMediaItem]
    let queue: PlaybackQueue<LibraryMediaItem.ID>?
    // Retention only. Build reconciliation snapshots from the raw queue on the
    // generic executor, without rebuilding unchanged queues from persisted data.
    let cachedQueueSnapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>?
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let unavailableItemIDs: Set<LibraryMediaItem.ID>
    let temporaryItemIDs: Set<LibraryMediaItem.ID>
    let currentItemID: LibraryMediaItem.ID?
    let loadedItemID: LibraryMediaItem.ID?
    let synchronizeLibraryQueue: Bool

    func prepare(
        using preparer: any MediaLibrarySnapshotPreparing
    ) async throws -> MediaLibraryPublicationPlan {
        try Task.checkCancellation()
        let library = prepared.library
        let libraryChanged = oldItems != library.items
        var queue = queue
        var queueItemsByID = queueItemsByID
        var currentItemID = currentItemID
        var loadedItemID = loadedItemID
        var visibleUnavailableItemIDs = Set(
            unavailableItemIDs.compactMap { library.itemsByID[$0]?.id }
        )
        var queueChanged = false

        if let snapshot = queue?.makeSnapshot() {
            let reconciliation = try await preparer.reconcileQueue(
                snapshot: snapshot,
                queueItemsByID: queueItemsByID,
                availableItemsByID: library.itemsByID,
                resolutionIndex: library.resolutionIndex
            )
            try Task.checkCancellation()
            queueItemsByID = reconciliation.queueItemsByID
            if reconciliation.requiresQueueReplacement,
               let replacementQueue = reconciliation.replacementQueue {
                queue = replacementQueue
                currentItemID = reconciliation.currentItemID
                loadedItemID = loadedItemID.map {
                    library.itemsByID[$0]?.id ?? $0
                }
                visibleUnavailableItemIDs = Set(
                    visibleUnavailableItemIDs.map {
                        library.itemsByID[$0]?.id ?? $0
                    }
                )
                queueChanged = true
            }
        }
        if queueItemsByID.isEmpty {
            queueItemsByID = library.itemsByID
        } else {
            queueItemsByID.merge(library.itemsByID) { _, visibleItem in visibleItem }
        }
        let completeRootPaths = Set(
            prepared.roots.lazy.map(\.id.standardizedPath).filter {
                !prepared.incompleteRootPaths.contains($0)
            }
        )
        try Task.checkCancellation()
        if synchronizeLibraryQueue, var activeQueue = queue {
            let completeRootPathComponents = completeRootPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.pathComponents
            }
            var synchronizedItemIDs = library.items.map(\.id)
            for (index, itemID) in activeQueue.items.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                guard library.itemsByID[itemID] == nil,
                      let queuedItem = queueItemsByID[itemID] else { continue }
                let mediaPathComponents = URL(
                    fileURLWithPath: queuedItem.id.standardizedMediaPath
                ).standardizedFileURL.pathComponents
                if !completeRootPathComponents.contains(where: {
                    mediaPathComponents.starts(with: $0)
                }) {
                    synchronizedItemIDs.append(itemID)
                }
            }
            if activeQueue.synchronizeItems(synchronizedItemIDs) {
                if activeQueue.isEmpty {
                    queue = nil
                    currentItemID = nil
                } else {
                    queue = activeQueue
                    currentItemID = activeQueue.currentItem
                }
                queueChanged = true
            }
        }
        if let activeQueue = queue {
            let activeItemIDs = Set(activeQueue.items)
            queueItemsByID = queueItemsByID.filter {
                activeItemIDs.contains($0.key)
            }
        } else if queueChanged {
            queueItemsByID.removeAll()
        }
        var temporaryItemIDs = temporaryItemIDs
        temporaryItemIDs.subtract(library.itemsByID.keys)
        if self.currentItemID != currentItemID { loadedItemID = nil }
        try Task.checkCancellation()
        return MediaLibraryPublicationPlan(
            libraryChanged: libraryChanged,
            queue: queue,
            currentItemID: currentItemID,
            loadedItemID: loadedItemID,
            queueItemsByID: queueItemsByID,
            unavailableItemIDs: visibleUnavailableItemIDs,
            unavailableChanged: unavailableItemIDs != visibleUnavailableItemIDs,
            temporaryItemIDs: temporaryItemIDs,
            queueChanged: queueChanged,
            keepingItemIDs: Set(library.itemsByID.keys),
            completeRootPaths: completeRootPaths
        )
    }
}

struct MediaLibraryPublicationPlan: Sendable {
    let libraryChanged: Bool
    let queue: PlaybackQueue<LibraryMediaItem.ID>?
    let currentItemID: LibraryMediaItem.ID?
    let loadedItemID: LibraryMediaItem.ID?
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let unavailableItemIDs: Set<LibraryMediaItem.ID>
    let unavailableChanged: Bool
    let temporaryItemIDs: Set<LibraryMediaItem.ID>
    let queueChanged: Bool
    let keepingItemIDs: Set<LibraryMediaItem.ID>
    let completeRootPaths: Set<String>
}
