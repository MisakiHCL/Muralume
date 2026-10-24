import Foundation

struct MediaLibraryQueueRestoreRequest: Sendable {
    let snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    let references: [MediaReference]
    let resolutionIndex: MediaReferenceResolutionIndex
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let collectionItems: [LibraryMediaItem]?
    let requestedRootPaths: Set<String>
    let visibleRootPaths: Set<String>
    let incompleteRootPaths: Set<String>
    let hasUnavailableSources: Bool
    let playbackOrder: PlaybackOrder
    let usesCustomShuffler: Bool
}

struct PreparedMediaLibraryQueueRestore: Sendable {
    let queue: PlaybackQueue<LibraryMediaItem.ID>
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
}

enum MediaLibraryQueueRestorePreparation: Sendable {
    case ready(PreparedMediaLibraryQueueRestore)
    case temporarilyUnavailable
    case invalidSnapshot
    case emptyQueue
}

protocol MediaLibraryQueueRestorationPreparing: Sendable {
    func prepare(_ request: MediaLibraryQueueRestoreRequest) async throws
        -> MediaLibraryQueueRestorePreparation
}

struct DefaultMediaLibraryQueueRestorationPreparer:
    MediaLibraryQueueRestorationPreparing {
    func prepare(_ request: MediaLibraryQueueRestoreRequest) async throws
        -> MediaLibraryQueueRestorePreparation {
        try Task.checkCancellation()
        let resolved = request.resolutionIndex.resolvePersistedQueueItems(
            queuedItemIDs: request.snapshot.items, references: request.references
        )
        try Task.checkCancellation()
        let canonical = remapped(request.snapshot, using: resolved)
        guard var queue = PlaybackQueue(snapshot: canonical) else {
            return .invalidSnapshot
        }
        try Task.checkCancellation()
        var missingIDs: Set<LibraryMediaItem.ID> = []
        for (offset, id) in canonical.items.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            if request.itemsByID[id] == nil { missingIDs.insert(id) }
        }
        if !missingIDs.isEmpty {
            let requested = components(request.requestedRootPaths)
            let visible = components(request.visibleRootPaths)
            let incomplete = components(request.incompleteRootPaths)
            for id in missingIDs {
                try Task.checkCancellation()
                let path = URL(fileURLWithPath: id.standardizedMediaPath)
                    .standardizedFileURL.pathComponents
                let isVisible = visible.contains { path.starts(with: $0) }
                if incomplete.contains(where: { path.starts(with: $0) })
                    || (requested.contains(where: { path.starts(with: $0) }) && !isVisible)
                    || (request.hasUnavailableSources && !isVisible) {
                    return .temporarilyUnavailable
                }
            }
            _ = queue.remove(missingIDs)
        }
        if let collectionItems = request.collectionItems {
            _ = queue.synchronizeItems(
                collectionItems.map(\.id), pendingOrderPolicy: .authoritative
            )
        }
        guard !queue.isEmpty else { return .emptyQueue }
        try Task.checkCancellation()
        if queue.order != request.playbackOrder {
            queue.setOrder(request.playbackOrder)
        } else if request.playbackOrder == .shuffled, !request.usesCustomShuffler {
            queue.reshufflePendingItems()
        }
        let activeIDs = Set(queue.items)
        let itemsByID = request.itemsByID.filter { activeIDs.contains($0.key) }
        try Task.checkCancellation()
        return .ready(.init(queue: queue, itemsByID: itemsByID))
    }

    private func components(_ paths: Set<String>) -> [[String]] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL.pathComponents }
    }

    private func remapped(
        _ snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        using resolved: [LibraryMediaItem.ID: LibraryMediaItem]
    ) -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        func canonical(_ id: LibraryMediaItem.ID) -> LibraryMediaItem.ID {
            resolved[id]?.id ?? id
        }
        func location(_ value: PlaybackQueueSnapshotLocation<LibraryMediaItem.ID>)
            -> PlaybackQueueSnapshotLocation<LibraryMediaItem.ID> {
            .init(item: canonical(value.item), roundNumber: value.roundNumber,
                  position: value.position)
        }
        return .init(
            items: snapshot.items.map(canonical), order: snapshot.order,
            currentItem: canonical(snapshot.currentItem), roundNumber: snapshot.roundNumber,
            currentRoundPosition: snapshot.currentRoundPosition,
            remainingItems: snapshot.remainingItems.map(canonical), remainingIndex: snapshot.remainingIndex,
            history: snapshot.history.map(location), forwardHistory: snapshot.forwardHistory.map(location)
        )
    }
}
