import Foundation

/// A filesystem-backed identity that normally survives a rename or move on
/// the same volume. Paths remain the first lookup key so hard links are never
/// silently collapsed; this identity is only used as an unambiguous fallback.
struct MediaFileIdentity: Codable, Hashable, Sendable {
    let volumeIdentifier: Data
    let fileIdentifier: Data

    var isValid: Bool {
        !volumeIdentifier.isEmpty && !fileIdentifier.isEmpty
    }
}

struct MediaReference: Codable, Hashable, Sendable {
    private(set) var mediaItemID: LibraryMediaItem.ID
    private(set) var fileIdentity: MediaFileIdentity?
    private(set) var lastKnownDisplayName: String

    init(item: LibraryMediaItem) {
        mediaItemID = item.id
        fileIdentity = item.fileIdentity
        lastKnownDisplayName = item.displayName
    }

    init(
        mediaItemID: LibraryMediaItem.ID,
        fileIdentity: MediaFileIdentity?,
        lastKnownDisplayName: String
    ) {
        self.mediaItemID = mediaItemID
        self.fileIdentity = fileIdentity?.isValid == true
            ? fileIdentity
            : nil
        self.lastKnownDisplayName = lastKnownDisplayName
    }

    var isValid: Bool {
        !mediaItemID.rootPath.isEmpty
            && !lastKnownDisplayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && (fileIdentity?.isValid ?? true)
    }

    func hasSameMedia(as item: LibraryMediaItem) -> Bool {
        if mediaItemID == item.id {
            return true
        }
        guard let fileIdentity, let itemIdentity = item.fileIdentity else {
            return false
        }
        return fileIdentity == itemIdentity
    }

    mutating func update(
        using item: LibraryMediaItem,
        adoptingFileIdentity: Bool = true
    ) {
        mediaItemID = item.id
        if adoptingFileIdentity {
            fileIdentity = item.fileIdentity ?? fileIdentity
        }
        lastKnownDisplayName = item.displayName
    }
}

struct MediaReferenceResolutionIndex: Sendable {
    private let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    private let itemsByFileIdentity: [
        MediaFileIdentity: [LibraryMediaItem]
    ]

    init(items: [LibraryMediaItem]) {
        var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        var itemsByFileIdentity: [
            MediaFileIdentity: [LibraryMediaItem]
        ] = [:]
        itemsByID.reserveCapacity(items.count)
        itemsByFileIdentity.reserveCapacity(items.count)

        for item in items {
            itemsByID[item.id] = item
            if let fileIdentity = item.fileIdentity {
                itemsByFileIdentity[fileIdentity, default: []].append(item)
            }
        }
        self.itemsByID = itemsByID
        self.itemsByFileIdentity = itemsByFileIdentity
    }

    func resolve(_ reference: MediaReference) -> LibraryMediaItem? {
        if let exactMatch = itemsByID[reference.mediaItemID] {
            return exactMatch
        }
        guard let fileIdentity = reference.fileIdentity,
              let identityMatches = itemsByFileIdentity[fileIdentity],
              identityMatches.count == 1 else {
            return nil
        }
        return identityMatches[0]
    }

    /// Resolves an ordered reference collection one-to-one. Exact paths claim
    /// their items before identity fallback, so a rename cannot make one
    /// current file satisfy two historical playlist entries.
    func resolveReferences(
        _ references: [MediaReference]
    ) -> [LibraryMediaItem?] {
        var resolvedItems = Array<LibraryMediaItem?>(
            repeating: nil,
            count: references.count
        )
        var claimedItemIDs: Set<LibraryMediaItem.ID> = []
        claimedItemIDs.reserveCapacity(references.count)

        for index in references.indices {
            guard let exactItem = itemsByID[references[index].mediaItemID],
                  claimedItemIDs.insert(exactItem.id).inserted else {
                continue
            }
            resolvedItems[index] = exactItem
        }

        for index in references.indices where resolvedItems[index] == nil {
            guard let fileIdentity = references[index].fileIdentity,
                  let identityMatches = itemsByFileIdentity[fileIdentity],
                  identityMatches.count == 1,
                  let identityMatch = identityMatches.first,
                  claimedItemIDs.insert(identityMatch.id).inserted else {
                continue
            }
            resolvedItems[index] = identityMatch
        }

        return resolvedItems
    }

    func resolvePersistedQueueItems(
        queuedItemIDs: [LibraryMediaItem.ID],
        references: [MediaReference]
    ) -> [LibraryMediaItem.ID: LibraryMediaItem] {
        var referencesByItemID: [LibraryMediaItem.ID: MediaReference] = [:]
        referencesByItemID.reserveCapacity(references.count)
        for reference in references {
            referencesByItemID[reference.mediaItemID] = reference
        }

        let orderedReferences = queuedItemIDs.map { itemID in
            referencesByItemID[itemID] ?? MediaReference(
                mediaItemID: itemID,
                fileIdentity: nil,
                lastKnownDisplayName: (itemID.relativePath as NSString)
                    .lastPathComponent
            )
        }
        let resolvedItems = resolveReferences(orderedReferences)
        var resolvedItemsByQueuedID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ] = [:]
        resolvedItemsByQueuedID.reserveCapacity(resolvedItems.count)
        for (queuedItemID, item) in zip(queuedItemIDs, resolvedItems) {
            if let item {
                resolvedItemsByQueuedID[queuedItemID] = item
            }
        }
        return resolvedItemsByQueuedID
    }

    /// Resolves queue members with exact paths first, then applies stable-file
    /// fallbacks only when the target has not already been claimed. This keeps
    /// rename reconciliation one-to-one even when old snapshots contain hard
    /// links or otherwise ambiguous historical identities.
    func resolveQueuedItems(
        _ queuedItemsByID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ]
    ) -> MediaReferenceQueueResolution {
        let queuedItemIDs = queuedItemsByID.keys.sorted {
            $0.standardizedMediaPath < $1.standardizedMediaPath
        }
        var resolvedItemsByQueuedID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ] = [:]
        var claimedItemIDs: Set<LibraryMediaItem.ID> = []
        var unresolvedItemIDs: [LibraryMediaItem.ID] = []
        resolvedItemsByQueuedID.reserveCapacity(queuedItemsByID.count)
        claimedItemIDs.reserveCapacity(queuedItemsByID.count)

        for queuedItemID in queuedItemIDs {
            guard let exactItem = itemsByID[queuedItemID] else {
                unresolvedItemIDs.append(queuedItemID)
                continue
            }
            resolvedItemsByQueuedID[queuedItemID] = exactItem
            claimedItemIDs.insert(exactItem.id)
        }

        for queuedItemID in unresolvedItemIDs {
            guard let queuedItem = queuedItemsByID[queuedItemID] else {
                continue
            }
            let candidate = resolve(MediaReference(item: queuedItem))
            let resolvedItem: LibraryMediaItem
            if let candidate, !claimedItemIDs.contains(candidate.id) {
                resolvedItem = candidate
            } else {
                resolvedItem = queuedItem
            }
            resolvedItemsByQueuedID[queuedItemID] = resolvedItem
            claimedItemIDs.insert(resolvedItem.id)
        }

        return MediaReferenceQueueResolution(
            resolvedItemsByQueuedID: resolvedItemsByQueuedID
        )
    }
}

struct MediaReferenceQueueResolution: Sendable {
    let resolvedItemsByQueuedID: [
        LibraryMediaItem.ID: LibraryMediaItem
    ]

    var canonicalItemsByID: [
        LibraryMediaItem.ID: LibraryMediaItem
    ] {
        Dictionary(
            uniqueKeysWithValues: resolvedItemsByQueuedID.values.map {
                ($0.id, $0)
            }
        )
    }
}
