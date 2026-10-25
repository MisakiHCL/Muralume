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

    private struct ResolvedPlaylistEntry {
        let media: MediaReference
        let item: LibraryMediaItem?
    }

    private struct ResolvedPlaylistCache {
        let playlistID: CustomPlaylist.ID
        var itemsRevision: UInt64
        var entries: [CustomPlaylistEntry]
        let entriesByID: [CustomPlaylistEntry.ID: ResolvedPlaylistEntry]
        var items: [LibraryMediaItem]
        let isOrderIndependent: Bool
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
    // A single playlist is retained, bounded by the persisted entry limit.
    // Library content changes, deletion/emptying and shutdown release it. A
    // revisionless lookup is never cached because its availability is unknown.
    private var resolvedPlaylistCache: ResolvedPlaylistCache?
    private(set) var resolvedItemsRecomputationCount = 0

    var hasCachedResolvedItems: Bool {
        resolvedPlaylistCache != nil
    }

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
            resolvedPlaylistCache = nil
        } else if resolvedPlaylistCache?.itemsRevision
                    == latestLibrarySnapshot?.itemsRevision,
                  let itemsRevision {
            // Sorting the library aliases the same immutable content.
            resolvedPlaylistCache?.itemsRevision = itemsRevision
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
              !playlist.entries.isEmpty else {
            if resolvedPlaylistCache?.playlistID == playlistID {
                resolvedPlaylistCache = nil
            }
            return []
        }
        if let itemsRevision, var cached = resolvedPlaylistCache,
           cached.playlistID == playlistID,
           cached.itemsRevision == itemsRevision {
            if cached.entries == playlist.entries { return cached.items }
            // Reordering is safe only when no reference competes for another
            // entry's identity fallback. Such conflicts must resolve afresh in
            // the new order to preserve exact-first, one-to-one selection.
            if cached.isOrderIndependent,
               cached.entries.count == playlist.entries.count,
               playlist.entries.allSatisfy({
                   cached.entriesByID[$0.id]?.media == $0.media
               }) {
                cached.entries = playlist.entries
                cached.items = playlist.entries.compactMap {
                    cached.entriesByID[$0.id]?.item
                }
                resolvedPlaylistCache = cached
                return cached.items
            }
        }
        let index = cachedResolutionIndex(itemsRevision: itemsRevision)
            ?? resolutionIndexCache.index(items: items, revision: itemsRevision)
        let resolved = index.resolveReferences(playlist.entries.map(\.media))
        let orderedItems = resolved.compactMap { $0 }
        resolvedItemsRecomputationCount &+= 1
        resolvedPlaylistCache = itemsRevision.map { revision in
            var entriesByID: [CustomPlaylistEntry.ID: ResolvedPlaylistEntry] = [:]
            entriesByID.reserveCapacity(playlist.entries.count)
            var isOrderIndependent = true
            for (entry, item) in zip(playlist.entries, resolved) {
                entriesByID[entry.id] = ResolvedPlaylistEntry(
                    media: entry.media, item: item
                )
                if item == nil, index.resolve(entry.media) != nil {
                    isOrderIndependent = false
                }
            }
            return ResolvedPlaylistCache(
                playlistID: playlistID,
                itemsRevision: revision,
                entries: playlist.entries,
                entriesByID: entriesByID,
                items: orderedItems,
                isOrderIndependent: isOrderIndependent
            )
        }
        return orderedItems
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
        resolvedPlaylistCache = nil
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
        if let cached = resolvedPlaylistCache,
           collection.playlist(id: cached.playlistID)?.entries.isEmpty != false {
            resolvedPlaylistCache = nil
        }
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
