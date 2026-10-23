import Combine
import Foundation

enum CustomPlaylistLoadingState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

enum CustomPlaylistPersistenceFailure: Equatable, Sendable {
    case saveFailed
}

@MainActor
final class CustomPlaylistController: ObservableObject {
    /// Detail search uses the revision as the identity of the collection, so
    /// both values must cross the @Published boundary together.
    private struct CollectionSnapshot {
        let revision: UInt64
        let collection: CustomPlaylistCollection
    }

    @Published private var collectionSnapshot = CollectionSnapshot(
        revision: 0,
        collection: .empty
    )
    @Published private(set) var loadingState: CustomPlaylistLoadingState = .idle
    @Published private(set) var persistenceFailure:
        CustomPlaylistPersistenceFailure?

    var collection: CustomPlaylistCollection {
        collectionSnapshot.collection
    }

    var playlists: [CustomPlaylist] {
        collection.playlists
    }

    var isReady: Bool {
        loadingState == .ready
    }

    var collectionRevision: UInt64 {
        collectionSnapshot.revision
    }

    var collectionPublisher: AnyPublisher<CustomPlaylistCollection, Never> {
        $collectionSnapshot
            .map(\.collection)
            .eraseToAnyPublisher()
    }

    private let store: any CustomPlaylistStoring
    private let resolutionIndexCache: MediaReferenceResolutionIndexCache
    private let detailProjectionCache: CustomPlaylistDetailProjectionCache
    private var lastReconciledItemsRevision: UInt64?

    var resolutionIndexRecomputationCount: Int {
        resolutionIndexCache.recomputationCount
    }

    var hasCachedDetailProjection: Bool {
        detailProjectionCache.hasCachedProjection
    }

    var hasCachedResolutionIndex: Bool {
        resolutionIndexCache.hasCachedIndex
    }
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var pendingSaveCollection: CustomPlaylistCollection?
    private var isShuttingDown = false

    init(store: any CustomPlaylistStoring) {
        self.store = store
        let resolutionIndexCache = MediaReferenceResolutionIndexCache()
        self.resolutionIndexCache = resolutionIndexCache
        detailProjectionCache = CustomPlaylistDetailProjectionCache(
            resolutionIndexCache: resolutionIndexCache
        )
    }

    func start() {
        guard loadingState == .idle, !isShuttingDown else {
            return
        }
        loadingState = .loading
        loadTask = Task { [weak self, store] in
            do {
                let collection = try await store.load()
                guard let self, !Task.isCancelled, !isShuttingDown else {
                    return
                }
                self.replaceCollection(collection)
                loadingState = .ready
            } catch {
                guard let self, !Task.isCancelled, !isShuttingDown else {
                    return
                }
                loadingState = .failed
            }
        }
    }

    func startAndWait() async {
        start()
        await loadTask?.value
    }

    func retryLoading() {
        guard loadingState == .failed, !isShuttingDown else {
            return
        }
        loadTask = nil
        loadingState = .idle
        start()
    }

    @discardableResult
    func createPlaylist(named name: String) throws -> CustomPlaylist.ID {
        try mutate { collection in
            try collection.createPlaylist(named: name)
        }
    }

    func renamePlaylist(id: CustomPlaylist.ID, to name: String) throws {
        try mutate { collection in
            try collection.renamePlaylist(id: id, to: name)
        }
    }

    func removePlaylist(id: CustomPlaylist.ID) throws {
        try mutate { collection in
            guard collection.removePlaylist(id: id) else {
                throw CustomPlaylistMutationError.playlistNotFound
            }
        }
    }

    @discardableResult
    func add(
        items: [LibraryMediaItem],
        to playlistID: CustomPlaylist.ID
    ) throws -> Int {
        try mutate { collection in
            try collection.add(items: items, to: playlistID)
        }
    }

    func removeEntry(
        _ entryID: CustomPlaylistEntry.ID,
        from playlistID: CustomPlaylist.ID
    ) throws {
        try mutate { collection in
            try collection.removeEntry(entryID, from: playlistID)
        }
    }

    func moveEntry(
        _ entryID: CustomPlaylistEntry.ID,
        before destinationID: CustomPlaylistEntry.ID?,
        in playlistID: CustomPlaylist.ID
    ) throws {
        try mutate { collection in
            try collection.moveEntry(
                entryID,
                before: destinationID,
                in: playlistID
            )
        }
    }

    func updateAvailableItems(
        _ items: [LibraryMediaItem],
        itemsRevision: UInt64? = nil
    ) {
        guard isReady else { return }
        if let itemsRevision, lastReconciledItemsRevision == itemsRevision {
            return
        }
        lastReconciledItemsRevision = itemsRevision
        detailProjectionCache.invalidate()
        resolutionIndexCache.invalidate()
        guard collection.playlists.contains(where: { !$0.entries.isEmpty }) else {
            return
        }
        var updatedCollection = collection
        guard updatedCollection.reconcile(
            using: resolutionIndexCache.index(items: items, revision: itemsRevision)
        ) else {
            return
        }
        replaceCollection(updatedCollection)
        scheduleSave()
    }

    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        collection requestedCollection: CustomPlaylistCollection? = nil,
        using items: [LibraryMediaItem],
        itemsRevision: UInt64? = nil
    ) -> [LibraryMediaItem] {
        let collection = requestedCollection ?? self.collection
        guard let playlist = collection.playlist(id: playlistID),
              !playlist.entries.isEmpty else { return [] }
        return resolutionIndexCache.index(items: items, revision: itemsRevision)
            .resolveReferences(playlist.entries.map(\.media)).compactMap { $0 }
    }

    func resolvedItemsByEntryID(
        in playlistID: CustomPlaylist.ID,
        using items: [LibraryMediaItem]
    ) -> [CustomPlaylistEntry.ID: LibraryMediaItem] {
        collection.resolvedItemsByEntryID(in: playlistID, using: items)
    }

    func detailSearchOperation(
        for playlist: CustomPlaylist,
        query: String,
        using items: [LibraryMediaItem],
        itemsRevision: UInt64
    ) -> LatestMediaSearch<CustomPlaylistDetailProjection>.Operation {
        let search = MediaCollectionSearch(query: query)
        let index = resolutionIndexCache.index(items: items, revision: itemsRevision)
        return {
            let entries = try search.filteredEntriesCancellable(from: playlist.entries)
            try Task.checkCancellation()
            let projection = CustomPlaylistDetailProjectionCache.makeProjection(
                search: search,
                entries: entries,
                resolutionIndex: index
            )
            try Task.checkCancellation()
            return projection
        }
    }

    func detailProjection(
        for playlist: CustomPlaylist,
        query: String,
        using items: [LibraryMediaItem],
        itemsRevision: UInt64
    ) -> CustomPlaylistDetailProjection {
        detailProjectionCache.projection(
            playlist: playlist,
            playlistRevision: collectionRevision,
            query: query,
            libraryItems: items,
            libraryItemsRevision: itemsRevision
        )
    }

    func retryPersistence() {
        guard isReady, persistenceFailure != nil else {
            return
        }
        scheduleSave()
    }

    func shutdown() async {
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        detailProjectionCache.invalidate()
        resolutionIndexCache.invalidate()
        loadTask?.cancel()
        await loadTask?.value
        loadTask = nil
        await persistenceTask?.value
        persistenceTask = nil
    }

    @discardableResult
    private func mutate<Result>(
        _ operation: (inout CustomPlaylistCollection) throws -> Result
    ) throws -> Result {
        guard isReady else {
            throw CustomPlaylistMutationError.playlistNotFound
        }
        var updatedCollection = collection
        let result = try operation(&updatedCollection)
        replaceCollection(updatedCollection)
        scheduleSave()
        return result
    }

    private func replaceCollection(_ collection: CustomPlaylistCollection) {
        detailProjectionCache.invalidate()
        if !collection.playlists.contains(where: { !$0.entries.isEmpty }) {
            resolutionIndexCache.invalidate()
        }
        collectionSnapshot = CollectionSnapshot(
            revision: collectionSnapshot.revision &+ 1,
            collection: collection
        )
        // Synchronous will-change observers may have read the previous
        // collection while the published snapshot was being replaced.
        detailProjectionCache.invalidate()
    }

    private func scheduleSave() {
        guard !isShuttingDown else {
            return
        }
        // Keep only the latest pending snapshot while the current write
        // finishes, so slow storage cannot accumulate tasks and collections.
        pendingSaveCollection = collection
        guard persistenceTask == nil else {
            return
        }
        persistenceTask = Task { [weak self, store] in
            defer {
                self?.persistenceTask = nil
            }
            while let collection = self?.takePendingSaveCollection() {
                do {
                    try await store.save(collection)
                    guard let self, !isShuttingDown else {
                        continue
                    }
                    persistenceFailure = nil
                } catch {
                    guard let self, !isShuttingDown else {
                        continue
                    }
                    persistenceFailure = .saveFailed
                }
            }
        }
    }

    private func takePendingSaveCollection() -> CustomPlaylistCollection? {
        defer {
            pendingSaveCollection = nil
        }
        return pendingSaveCollection
    }
}
