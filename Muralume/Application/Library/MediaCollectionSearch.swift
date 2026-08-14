import Foundation

/// Shared media search semantics for library and custom-playlist surfaces.
/// Filtering is stable: matching values keep their original collection order.
struct MediaCollectionSearch: Equatable, Sendable {
    let query: String

    init(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        query.isEmpty
    }

    func filteredItems(
        from items: [LibraryMediaItem]
    ) -> [LibraryMediaItem] {
        guard !isEmpty else {
            return items
        }
        return items.filter(matches)
    }

    func filteredEntries(
        from entries: [CustomPlaylistEntry]
    ) -> [CustomPlaylistEntry] {
        guard !isEmpty else {
            return entries
        }
        return entries.filter(matches)
    }

    func matches(_ item: LibraryMediaItem) -> Bool {
        matchesAny(
            item.displayName,
            item.relativePath,
            item.relativeDirectory,
            item.rootName
        )
    }

    func matches(_ entry: CustomPlaylistEntry) -> Bool {
        let itemID = entry.media.mediaItemID
        let relativeDirectory = (itemID.relativePath as NSString)
            .deletingLastPathComponent
        let rootName = URL(fileURLWithPath: itemID.rootPath)
            .lastPathComponent

        return matchesAny(
            entry.media.lastKnownDisplayName,
            itemID.relativePath,
            relativeDirectory,
            rootName,
            itemID.rootPath
        )
    }

    private func matchesAny(_ values: String...) -> Bool {
        values.contains { $0.localizedStandardContains(query) }
    }
}

/// A single-revision projection keeps SwiftUI body recomputation from
/// repeatedly scanning the same media collection for status text, empty-state
/// decisions, and table content.
struct MediaLibrarySearchProjection: Sendable {
    let search: MediaCollectionSearch
    let items: [LibraryMediaItem]
}

final class MediaLibrarySearchProjectionCache {
    private struct Key: Equatable {
        let itemsRevision: UInt64
        let query: String
    }

    private var cached: (key: Key, projection: MediaLibrarySearchProjection)?
    private(set) var recomputationCount = 0

    func projection(
        query: String,
        itemsRevision: UInt64,
        items: [LibraryMediaItem]
    ) -> MediaLibrarySearchProjection {
        let search = MediaCollectionSearch(query: query)
        let key = Key(itemsRevision: itemsRevision, query: search.query)
        if let cached, cached.key == key {
            return cached.projection
        }

        let projection = MediaLibrarySearchProjection(
            search: search,
            items: search.filteredItems(from: items)
        )
        cached = (key, projection)
        recomputationCount &+= 1
        return projection
    }
}

struct CustomPlaylistDetailProjection: Sendable {
    let search: MediaCollectionSearch
    let entries: [CustomPlaylistEntry]
    let resolvedItemsByEntryID: [
        CustomPlaylistEntry.ID: LibraryMediaItem
    ]
    private let entryIDsByMediaItemID: [
        LibraryMediaItem.ID: CustomPlaylistEntry.ID
    ]

    fileprivate init(
        search: MediaCollectionSearch,
        entries: [CustomPlaylistEntry],
        resolvedItemsByEntryID: [
            CustomPlaylistEntry.ID: LibraryMediaItem
        ],
        entryIDsByMediaItemID: [
            LibraryMediaItem.ID: CustomPlaylistEntry.ID
        ]
    ) {
        self.search = search
        self.entries = entries
        self.resolvedItemsByEntryID = resolvedItemsByEntryID
        self.entryIDsByMediaItemID = entryIDsByMediaItemID
    }

    func entryID(for mediaItemID: LibraryMediaItem.ID?)
        -> CustomPlaylistEntry.ID? {
        mediaItemID.flatMap { entryIDsByMediaItemID[$0] }
    }
}

final class CustomPlaylistDetailProjectionCache {
    private struct Key: Equatable {
        let playlistID: CustomPlaylist.ID
        let playlistRevision: UInt64
        let libraryItemsRevision: UInt64
        let query: String
    }

    private var cached: (key: Key, projection: CustomPlaylistDetailProjection)?
    private var cachedResolutionIndex: (
        libraryItemsRevision: UInt64,
        index: MediaReferenceResolutionIndex
    )?
    private(set) var recomputationCount = 0
    private(set) var resolutionIndexRecomputationCount = 0

    func projection(
        playlist: CustomPlaylist,
        playlistRevision: UInt64,
        query: String,
        libraryItems: [LibraryMediaItem],
        libraryItemsRevision: UInt64
    ) -> CustomPlaylistDetailProjection {
        let search = MediaCollectionSearch(query: query)
        let key = Key(
            playlistID: playlist.id,
            playlistRevision: playlistRevision,
            libraryItemsRevision: libraryItemsRevision,
            query: search.query
        )
        if let cached, cached.key == key {
            return cached.projection
        }

        let entries = search.filteredEntries(from: playlist.entries)
        let resolvedItems = resolutionIndex(
            libraryItems: libraryItems,
            libraryItemsRevision: libraryItemsRevision
        ).resolveReferences(entries.map(\.media))
        var resolvedItemsByEntryID: [
            CustomPlaylistEntry.ID: LibraryMediaItem
        ] = [:]
        var entryIDsByMediaItemID: [
            LibraryMediaItem.ID: CustomPlaylistEntry.ID
        ] = [:]
        resolvedItemsByEntryID.reserveCapacity(entries.count)
        entryIDsByMediaItemID.reserveCapacity(entries.count)
        for (entry, item) in zip(entries, resolvedItems) {
            guard let item else { continue }
            resolvedItemsByEntryID[entry.id] = item
            entryIDsByMediaItemID[item.id] = entry.id
        }

        let projection = CustomPlaylistDetailProjection(
            search: search,
            entries: entries,
            resolvedItemsByEntryID: resolvedItemsByEntryID,
            entryIDsByMediaItemID: entryIDsByMediaItemID
        )
        cached = (key, projection)
        recomputationCount &+= 1
        return projection
    }

    private func resolutionIndex(
        libraryItems: [LibraryMediaItem],
        libraryItemsRevision: UInt64
    ) -> MediaReferenceResolutionIndex {
        if let cachedResolutionIndex,
           cachedResolutionIndex.libraryItemsRevision
            == libraryItemsRevision {
            return cachedResolutionIndex.index
        }
        let index = MediaReferenceResolutionIndex(items: libraryItems)
        cachedResolutionIndex = (libraryItemsRevision, index)
        resolutionIndexRecomputationCount &+= 1
        return index
    }
}
