import Combine
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

    func filteredItemsCancellable(
        from items: [LibraryMediaItem]
    ) throws -> [LibraryMediaItem] {
        try filterCancellable(items, matches: matches)
    }

    func filteredEntriesCancellable(
        from entries: [CustomPlaylistEntry]
    ) throws -> [CustomPlaylistEntry] {
        try filterCancellable(entries, matches: matches)
    }

    private func filterCancellable<Value>(
        _ values: [Value],
        matches: (Value) -> Bool
    ) throws -> [Value] {
        try Task.checkCancellation()
        guard !isEmpty else { return values }
        var result: [Value] = []
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if matches(value) { result.append(value) }
        }
        try Task.checkCancellation()
        return result
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

    func invalidate() {
        cached = nil
    }

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

/// A library revision owns one immutable resolution index. The playlist
/// controller invalidates it as soon as the library changes, even off-screen.
final class MediaReferenceResolutionIndexCache {
    private var cached: (revision: UInt64, index: MediaReferenceResolutionIndex)?
    private(set) var recomputationCount = 0

    var hasCachedIndex: Bool { cached != nil }

    func invalidate() {
        cached = nil
    }

    func index(
        items: [LibraryMediaItem],
        revision: UInt64?
    ) -> MediaReferenceResolutionIndex {
        if let revision, let cached, cached.revision == revision {
            return cached.index
        }
        let index = MediaReferenceResolutionIndex(items: items)
        cached = revision.map { ($0, index) }
        recomputationCount &+= 1
        return index
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
    private let resolutionIndexCache: MediaReferenceResolutionIndexCache
    private(set) var recomputationCount = 0

    init(
        resolutionIndexCache: MediaReferenceResolutionIndexCache =
            MediaReferenceResolutionIndexCache()
    ) {
        self.resolutionIndexCache = resolutionIndexCache
    }

    var resolutionIndexRecomputationCount: Int {
        resolutionIndexCache.recomputationCount
    }

    var hasCachedProjection: Bool { cached != nil }

    func invalidate() {
        cached = nil
    }

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
        let projection = Self.makeProjection(
            search: search,
            entries: search.filteredEntries(from: playlist.entries),
            resolutionIndex: resolutionIndexCache.index(
                items: libraryItems,
                revision: libraryItemsRevision
            )
        )
        cached = (key, projection)
        recomputationCount &+= 1
        return projection
    }

    static func makeProjection(
        search: MediaCollectionSearch,
        entries: [CustomPlaylistEntry],
        resolutionIndex: MediaReferenceResolutionIndex
    ) -> CustomPlaylistDetailProjection {
        let resolvedItems = resolutionIndex.resolveReferences(entries.map(\.media))
        var resolvedItemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem] = [:]
        var entryIDsByMediaItemID: [LibraryMediaItem.ID: CustomPlaylistEntry.ID] = [:]
        resolvedItemsByEntryID.reserveCapacity(entries.count)
        entryIDsByMediaItemID.reserveCapacity(entries.count)
        for (entry, item) in zip(entries, resolvedItems) {
            guard let item else { continue }
            resolvedItemsByEntryID[entry.id] = item
            entryIDsByMediaItemID[item.id] = entry.id
        }
        return CustomPlaylistDetailProjection(
            search: search,
            entries: entries,
            resolvedItemsByEntryID: resolvedItemsByEntryID,
            entryIDsByMediaItemID: entryIDsByMediaItemID
        )
    }
}

struct MediaLibrarySearchRequestID: Hashable {
    let itemsRevision: UInt64
    let query: String
}

struct CustomPlaylistSearchRequestID: Hashable {
    let playlistID: CustomPlaylist.ID
    let playlistRevision: UInt64
    let libraryItemsRevision: UInt64
    let query: String
}

/// One running job and one latest pending request bound work and retained
/// snapshots during rapid typing. A cancelled job must finish before the next
/// starts; both cancellation and request identity gate result publication.
@MainActor
final class LatestMediaSearch<Result: Sendable>: ObservableObject {
    typealias Operation = @Sendable () async throws -> Result

    private struct Request {
        let key: AnyHashable
        let operation: Operation
    }

    @Published private var completed: (key: AnyHashable, result: Result)?
    private var requestedKey: AnyHashable?
    private var pending: Request?
    private var drainTask: Task<Void, Never>?
    private var workerTask: Task<Result, Error>?

    deinit {
        workerTask?.cancel()
        drainTask?.cancel()
    }

    func result(for key: some Hashable) -> Result? {
        guard completed?.key == AnyHashable(key) else { return nil }
        return completed?.result
    }

    func latestResult<Key: Hashable>(
        compatibleWith key: Key,
        by isCompatible: (Key, Key) -> Bool
    ) -> (key: Key, result: Result)? {
        guard let completed,
              let completedKey = completed.key.base as? Key,
              isCompatible(completedKey, key) else { return nil }
        return (completedKey, completed.result)
    }

    func request(key: some Hashable, operation: @escaping Operation) {
        let key = AnyHashable(key)
        guard requestedKey != key else { return }
        requestedKey = key
        pending = Request(key: key, operation: operation)
        workerTask?.cancel()
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while let request = self?.takePendingRequest() {
                let operation = request.operation
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await operation()
                }
                self?.workerTask = worker
                let result = try? await worker.value
                guard let self else { return }
                workerTask = nil
                if requestedKey == request.key, !worker.isCancelled, let result {
                    completed = (request.key, result)
                }
            }
            self?.drainTask = nil
        }
    }

    func cancel() {
        requestedKey = nil
        pending = nil
        workerTask?.cancel()
        completed = nil
    }

    func waitForPendingSearch() async {
        await drainTask?.value
    }

    private func takePendingRequest() -> Request? {
        defer { pending = nil }
        return pending
    }
}
