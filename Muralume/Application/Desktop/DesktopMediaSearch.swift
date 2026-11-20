import Foundation

struct DesktopMediaChoices {
    let items: [LibraryMediaItem]
    let libraryItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let playlistItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]

    init(
        libraryItems: [LibraryMediaItem] = [],
        libraryItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:],
        playlistItems: [LibraryMediaItem] = []
    ) {
        self.libraryItemsByID = libraryItemsByID
        var additionalItems: [LibraryMediaItem] = []
        var additionalItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        for item in playlistItems where item.accessLease != nil {
            guard libraryItemsByID[item.id] == nil,
                  additionalItemsByID[item.id] == nil else { continue }
            additionalItemsByID[item.id] = item
            additionalItems.append(item)
        }
        items = additionalItems.isEmpty ? libraryItems : libraryItems + additionalItems
        playlistItemsByID = additionalItemsByID
    }

    subscript(id: LibraryMediaItem.ID) -> LibraryMediaItem? {
        libraryItemsByID[id] ?? playlistItemsByID[id]
    }

    subscript(assignment: DesktopDisplayAssignment) -> LibraryMediaItem? {
        guard let itemID = assignment.mediaItemID,
              let item = self[itemID],
              assignment.matchesMediaIdentity(item.fileIdentity) else { return nil }
        return item
    }

    static func playbackItem(
        libraryItem: LibraryMediaItem?, playlistItem: LibraryMediaItem?
    ) -> LibraryMediaItem? {
        // The playlist resolver can still describe the old file after a
        // library scan detects a same-path substitution. Use the identity
        // visible in the picker while the playlist catches up.
        if let libraryItem, let identity = libraryItem.fileIdentity,
           playlistItem?.fileIdentity != identity {
            return libraryItem
        }
        return playlistItem ?? libraryItem
    }
}

/// The desktop picker searches three visible fields. Keep this distinct from
/// library search, which also matches the complete relative media filename.
struct DesktopMediaSearch: Sendable {
    let query: String

    init(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func updateProjection(
        _ projection: LatestMediaSearch<[LibraryMediaItem]>,
        requestID: DesktopMediaSearchRequestID,
        items: [LibraryMediaItem]
    ) {
        // SwiftUI can cancel a queued .task before it enters this body. It
        // must not restart work after onDisappear has cleared the projection.
        guard !Task.isCancelled else { return }
        if query.isEmpty {
            projection.cancel()
        } else {
            projection.request(key: requestID) {
                try filteredItemsCancellable(from: items)
            }
        }
    }

    func filteredItemsCancellable(
        from items: [LibraryMediaItem]
    ) throws -> [LibraryMediaItem] {
        try Task.checkCancellation()
        guard !query.isEmpty else { return items }
        var matches: [LibraryMediaItem] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if item.displayName.localizedStandardContains(query)
                || item.rootName.localizedStandardContains(query)
                || item.relativeDirectory.localizedStandardContains(query) {
                matches.append(item)
            }
        }
        try Task.checkCancellation()
        return matches
    }
}

/// The immutable ordered library snapshot and locale invalidate old results.
/// LatestMediaSearch owns at most one worker and one latest pending snapshot;
/// leaving the picker clears the completed projection and cancels its work.
struct DesktopMediaSearchRequestID: Hashable {
    let itemsRevision: UInt64
    let query: String
    let localeIdentifier: String
    let systemLocaleIdentifier: String
}
