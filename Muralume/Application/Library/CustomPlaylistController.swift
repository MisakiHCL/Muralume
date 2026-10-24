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
    typealias ReconcileOperation = @Sendable (
        CustomPlaylistCollection,
        MediaReferenceResolutionIndex
    ) async throws -> CustomPlaylistCollection?

    private struct LibrarySnapshot: Sendable {
        let generation: UInt64
        let contentRevision: UInt64?
        let itemsRevision: UInt64?
        let items: [LibraryMediaItem]
        let resolutionIndex: MediaReferenceResolutionIndex?
    }

    private struct ReconciliationKey: Equatable, Sendable {
        let libraryGeneration: UInt64
        let collectionRevision: UInt64
    }

    private struct ReconciliationRequest: Sendable {
        let library: LibrarySnapshot
        let collectionRevision: UInt64
        let collection: CustomPlaylistCollection

        var key: ReconciliationKey {
            ReconciliationKey(
                libraryGeneration: library.generation,
                collectionRevision: collectionRevision
            )
        }
    }

    private struct ReconciliationResult: Sendable {
        let index: MediaReferenceResolutionIndex
        let builtIndex: Bool
        let collection: CustomPlaylistCollection?
    }

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
    private let reconcileOperation: ReconcileOperation
    private var latestLibrarySnapshot: LibrarySnapshot?
    private var libraryGeneration: UInt64 = 0
    private var pendingReconciliation: ReconciliationRequest?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationWorker: Task<ReconciliationResult, Error>?
    private var runningReconciliationKey: ReconciliationKey?
    private var reconciledLibraryGeneration: UInt64?
    private var reconciledCollectionRevision: UInt64?

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

    init(
        store: any CustomPlaylistStoring,
        reconcileOperation: @escaping ReconcileOperation = { collection, index in
            var updated = collection
            return try updated.reconcileCancellable(using: index) ? updated : nil
        }
    ) {
        self.store = store
        self.reconcileOperation = reconcileOperation
        let resolutionIndexCache = MediaReferenceResolutionIndexCache()
        self.resolutionIndexCache = resolutionIndexCache
        detailProjectionCache = CustomPlaylistDetailProjectionCache(
            resolutionIndexCache: resolutionIndexCache
        )
    }

    deinit {
        reconciliationWorker?.cancel()
        reconciliationTask?.cancel()
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
        itemsRevision: UInt64? = nil,
        contentRevision: UInt64? = nil,
        resolutionIndex: MediaReferenceResolutionIndex? = nil
    ) {
        guard isReady else { return }
        let contentRevision = contentRevision ?? itemsRevision
        let contentIsUnchanged = contentRevision != nil
            && latestLibrarySnapshot?.contentRevision == contentRevision
        if !contentIsUnchanged {
            libraryGeneration &+= 1
            detailProjectionCache.invalidate()
            resolutionIndexCache.invalidate()
        }
        // The production library supplies an index prepared off-main. A pure
        // reorder only changes its revision alias, preserving immutable storage.
        let index = resolutionIndex ?? (contentIsUnchanged
            ? latestLibrarySnapshot?.resolutionIndex
            : nil)
        latestLibrarySnapshot = LibrarySnapshot(
            generation: libraryGeneration,
            contentRevision: contentRevision,
            itemsRevision: itemsRevision,
            items: items,
            resolutionIndex: index
        )
        if let index, collection.playlists.contains(where: { !$0.entries.isEmpty }) {
            resolutionIndexCache.install(
                index,
                revision: itemsRevision,
                countsAsRecomputation: !contentIsUnchanged
            )
        }
        scheduleReconciliation()
    }

    func waitForLibraryReconciliation() async {
        await reconciliationTask?.value
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
        let index = cachedResolutionIndex(itemsRevision: itemsRevision)
            ?? resolutionIndexCache.index(items: items, revision: itemsRevision)
        return index
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
        let cachedIndex = cachedResolutionIndex(itemsRevision: itemsRevision)
        return {
            try Task.checkCancellation()
            let index = cachedIndex ?? MediaReferenceResolutionIndex(items: items)
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
        pendingReconciliation = nil
        reconciliationWorker?.cancel()
        await reconciliationTask?.value
        reconciliationTask = nil
        latestLibrarySnapshot = nil
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

    private func replaceCollection(
        _ collection: CustomPlaylistCollection,
        schedulesReconciliation: Bool = true
    ) {
        detailProjectionCache.invalidate()
        if !collection.playlists.contains(where: { !$0.entries.isEmpty }) {
            resolutionIndexCache.invalidate()
        } else if let library = latestLibrarySnapshot,
                  let index = library.resolutionIndex {
            resolutionIndexCache.install(
                index,
                revision: library.itemsRevision,
                countsAsRecomputation: false
            )
        }
        collectionSnapshot = CollectionSnapshot(
            revision: collectionSnapshot.revision &+ 1,
            collection: collection
        )
        // Synchronous will-change observers may have read the previous
        // collection while the published snapshot was being replaced.
        detailProjectionCache.invalidate()
        if schedulesReconciliation { scheduleReconciliation() }
    }

    private func scheduleReconciliation() {
        guard !isShuttingDown, let library = latestLibrarySnapshot else { return }
        guard collection.playlists.contains(where: { !$0.entries.isEmpty }) else {
            pendingReconciliation = nil
            reconciliationWorker?.cancel()
            resolutionIndexCache.invalidate()
            return
        }
        guard reconciledLibraryGeneration != library.generation
            || reconciledCollectionRevision != collectionRevision else { return }
        let request = ReconciliationRequest(
            library: library,
            collectionRevision: collectionRevision,
            collection: collection
        )
        guard runningReconciliationKey != request.key else { return }
        pendingReconciliation = request
        reconciliationWorker?.cancel()
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { [weak self] in
            while let request = self?.takePendingReconciliation() {
                guard let operation = self?.reconcileOperation else { return }
                self?.runningReconciliationKey = request.key
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let index = request.library.resolutionIndex
                        ?? MediaReferenceResolutionIndex(items: request.library.items)
                    let collection = try await operation(request.collection, index)
                    try Task.checkCancellation()
                    return ReconciliationResult(
                        index: index,
                        builtIndex: request.library.resolutionIndex == nil,
                        collection: collection
                    )
                }
                self?.reconciliationWorker = worker
                let result = try? await worker.value
                guard let self else { return }
                reconciliationWorker = nil
                runningReconciliationKey = nil
                guard !isShuttingDown, let result,
                      let latest = latestLibrarySnapshot,
                      latest.generation == request.library.generation,
                      collectionRevision == request.collectionRevision else { continue }
                latestLibrarySnapshot = LibrarySnapshot(
                    generation: latest.generation,
                    contentRevision: latest.contentRevision,
                    itemsRevision: latest.itemsRevision,
                    items: latest.items,
                    resolutionIndex: result.index
                )
                resolutionIndexCache.install(
                    result.index,
                    revision: latest.itemsRevision,
                    countsAsRecomputation: result.builtIndex
                )
                if let updatedCollection = result.collection {
                    replaceCollection(updatedCollection, schedulesReconciliation: false)
                    scheduleSave()
                }
                reconciledLibraryGeneration = latest.generation
                reconciledCollectionRevision = collectionRevision
            }
            self?.reconciliationTask = nil
        }
    }

    private func takePendingReconciliation() -> ReconciliationRequest? {
        defer { pendingReconciliation = nil }
        return pendingReconciliation
    }

    private func cachedResolutionIndex(
        itemsRevision: UInt64?
    ) -> MediaReferenceResolutionIndex? {
        if let cached = resolutionIndexCache.cachedIndex(revision: itemsRevision) {
            return cached
        }
        guard let itemsRevision,
              latestLibrarySnapshot?.itemsRevision == itemsRevision else { return nil }
        return latestLibrarySnapshot?.resolutionIndex
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
