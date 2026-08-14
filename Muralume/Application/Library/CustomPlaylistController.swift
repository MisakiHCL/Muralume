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
    private let detailProjectionCache = CustomPlaylistDetailProjectionCache()
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(store: any CustomPlaylistStoring) {
        self.store = store
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

    func updateAvailableItems(_ items: [LibraryMediaItem]) {
        guard isReady else {
            return
        }
        var updatedCollection = collection
        guard updatedCollection.reconcile(using: items) else {
            return
        }
        replaceCollection(updatedCollection)
        scheduleSave()
    }

    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        using items: [LibraryMediaItem]
    ) -> [LibraryMediaItem] {
        collection.resolvedItems(in: playlistID, using: items)
    }

    func resolvedItemsByEntryID(
        in playlistID: CustomPlaylist.ID,
        using items: [LibraryMediaItem]
    ) -> [CustomPlaylistEntry.ID: LibraryMediaItem] {
        collection.resolvedItemsByEntryID(
            in: playlistID,
            using: items
        )
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
        collectionSnapshot = CollectionSnapshot(
            revision: collectionSnapshot.revision &+ 1,
            collection: collection
        )
    }

    private func scheduleSave() {
        guard !isShuttingDown else {
            return
        }
        let collection = collection
        let previousTask = persistenceTask
        persistenceTask = Task { [weak self, store] in
            await previousTask?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await store.save(collection)
                guard let self, !isShuttingDown else {
                    return
                }
                persistenceFailure = nil
            } catch {
                guard let self, !isShuttingDown else {
                    return
                }
                persistenceFailure = .saveFailed
            }
        }
    }
}
