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

enum CustomPlaylistCreationInputError: Error, Equatable {
    case selectionChanged
}

/// An ordered user input snapshot, independent from later search and selection changes.
struct CustomPlaylistCreationInput: Sendable {
    let items: [LibraryMediaItem]

    func validatedItems(
        using itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) throws -> [LibraryMediaItem] {
        return try items.map { item in
            guard let current = itemsByID[item.id],
                  MediaBrowserItemIdentity(current) == MediaBrowserItemIdentity(item) else {
                throw CustomPlaylistCreationInputError.selectionChanged
            }
            return current
        }
    }
}

@MainActor
final class CustomPlaylistController: ObservableObject {
    typealias GrantCapture = @MainActor (LibraryMediaItem) -> CustomPlaylistMediaGrant?
    typealias SourceGrantCapture = @MainActor (MediaSource.ID) -> CustomPlaylistMediaGrant?
    typealias ResolutionPublication = (
        items: [LibraryMediaItem], itemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem],
        revision: UInt64, availabilityRevision: UInt64
    )
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

    var usesIndependentMediaAccess: Bool { mediaCatalog != nil }
    var resolutionItems: [LibraryMediaItem] { currentMediaSnapshot.items }
    var resolutionRevision: UInt64 { currentMediaSnapshot.revision }
    var availabilityRevision: UInt64 { currentMediaSnapshot.availabilityRevision }
    var authorizedRootIDs: Set<MediaLibraryRoot.ID> { currentMediaSnapshot.authorizedRootIDs }

    var resolutionPublisher: AnyPublisher<ResolutionPublication, Never> {
        let publisher = mediaCatalog.map { $0.$snapshot } ?? $legacyMediaSnapshot
        return publisher.map {
            (items: $0.items, itemsByEntryID: $0.itemsByEntryID,
             revision: $0.revision, availabilityRevision: $0.availabilityRevision)
        }.eraseToAnyPublisher()
    }

    private var currentMediaSnapshot: CustomPlaylistMediaCatalogSnapshot {
        mediaCatalog?.snapshot ?? legacyMediaSnapshot
    }

    func issue(for entry: CustomPlaylistEntry) -> CustomPlaylistMediaIssue? {
        guard let mediaCatalog else { return nil }
        if mediaCatalog.snapshot.itemsByEntryID[entry.id] != nil { return nil }
        return mediaCatalog.snapshot.issuesByEntryID[entry.id]
            ?? (entry.accessGrantID == nil ? .authorizationRequired : .resolving)
    }

    func retryResolution() {
        guard isReady, !isShuttingDown else { return }
        if let library = latestLibrarySnapshot {
            backfillAccessGrants(using: library.items, index: library.resolutionIndex)
        }
        mediaCatalog?.update(collection, force: true)
    }

    func waitForMediaResolution() async { await mediaCatalog?.waitForResolution() }

    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        collection requestedCollection: CustomPlaylistCollection? = nil
    ) -> [LibraryMediaItem] {
        guard let playlist = (requestedCollection ?? collection).playlist(id: playlistID) else { return [] }
        if let mediaCatalog {
            return playlist.entries.compactMap { mediaCatalog.snapshot.itemsByEntryID[$0.id] }
        }
        return resolvedItems(
            in: playlistID, collection: requestedCollection,
            using: latestLibrarySnapshot?.items ?? [], itemsRevision: latestLibrarySnapshot?.itemsRevision
        )
    }

    /// Consumers of resolutionPublisher must use the incoming entry map:
    /// @Published has not installed it as the current snapshot during its sink.
    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        collection requestedCollection: CustomPlaylistCollection? = nil,
        usingEntryItems itemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem]
    ) -> [LibraryMediaItem] {
        guard let playlist = (requestedCollection ?? collection).playlist(id: playlistID) else { return [] }
        return playlist.entries.compactMap { itemsByEntryID[$0.id] }
    }

    func detailSearchOperation(
        for playlist: CustomPlaylist, query: String
    ) -> LatestMediaSearch<CustomPlaylistDetailProjection>.Operation {
        guard let mediaCatalog else {
            return detailSearchOperation(
                for: playlist, query: query, using: latestLibrarySnapshot?.items ?? [],
                itemsRevision: latestLibrarySnapshot?.itemsRevision ?? 0
            )
        }
        let search = MediaCollectionSearch(query: query)
        let resolved = mediaCatalog.snapshot.itemsByEntryID
        return {
            let entries = try search.filteredEntriesCancellable(from: playlist.entries)
            try Task.checkCancellation()
            return CustomPlaylistDetailProjectionCache.makeProjection(
                search: search, entries: entries, resolvedItemsByEntryID: resolved
            )
        }
    }

    func reauthorizationSource(
        for entryID: CustomPlaylistEntry.ID, in playlistID: CustomPlaylist.ID
    ) -> UnavailableMediaSource? {
        guard let entry = collection.playlist(id: playlistID)?.entries.first(where: { $0.id == entryID }) else {
            return nil
        }
        let grant = entry.accessGrantID.flatMap { id in collection.accessGrants.first { $0.id == id } }
        let path = grant?.sourcePath ?? entry.media.mediaItemID.rootPath
        let url = URL(fileURLWithPath: path)
        return UnavailableMediaSource(
            id: .init(rawValue: grant?.id.uuidString ?? entry.id.rawValue.uuidString),
            displayName: url.lastPathComponent, lastKnownURL: url,
            kind: grant?.kind ?? (entry.media.mediaItemID.relativePath.isEmpty ? .file : .folder)
        )
    }

    func reauthorizeEntry(
        playlistID: CustomPlaylist.ID, entryID: CustomPlaylistEntry.ID, selectedURL: URL
    ) async throws {
        guard let mediaResolver,
              let source = reauthorizationSource(for: entryID, in: playlistID),
              let entry = collection.playlist(id: playlistID)?.entries.first(where: { $0.id == entryID }),
              let grant = await mediaResolver.authorize(
                selectedURL: selectedURL, sourcePath: source.lastKnownURL.path,
                kind: source.kind, grantID: entry.accessGrantID
              ), !isShuttingDown else {
            throw CustomPlaylistMutationError.authorizationUnavailable
        }
        try mutate { collection in
            _ = try collection.installReauthorizedGrant(grant, legacySourcePath: source.lastKnownURL.path)
        }
        mediaCatalog?.update(collection, force: true)
        await waitForMediaResolution()
        guard await flushPersistence() else { throw CustomPlaylistMutationError.authorizationUnavailable }
    }

    func prepareForSourceRemoval(_ root: MediaLibraryRoot) async -> Bool {
        guard mediaCatalog != nil else { return true }
        guard isReady, !isShuttingDown else { return false }
        if let library = latestLibrarySnapshot {
            backfillAccessGrants(using: library.items, index: library.resolutionIndex)
        }
        await waitForMediaResolution()
        let rootParts = root.url.standardizedFileURL.pathComponents
        let grants = Dictionary(uniqueKeysWithValues: collection.accessGrants.map { ($0.id, $0) })
        for entry in collection.allEntries {
            let pathParts = URL(fileURLWithPath: entry.media.mediaItemID.standardizedMediaPath).pathComponents
            let grant = entry.accessGrantID.flatMap { grants[$0] }
            let belongsToRoot = pathParts.starts(with: rootParts)
                || grant?.sourcePath == root.id.standardizedPath
            guard belongsToRoot else { continue }
            guard let grant, authorizedRootIDs.contains(.init(standardizedPath: grant.sourcePath)) else { return false }
        }
        return await flushPersistence()
    }

    /// Source metadata is sufficient even when a referenced child is missing.
    /// This never asks the scanner to invent a playable item for that child.
    func refreshAccessGrantsFromSources() {
        guard isReady, !isShuttingDown, let mediaCatalog else { return }
        backfillAccessGrants(
            using: latestLibrarySnapshot?.items ?? [], index: latestLibrarySnapshot?.resolutionIndex
        )
        mediaCatalog.update(collection, force: true)
    }

    func prepareForUnavailableSourceRemoval(_ source: UnavailableMediaSource) async -> Bool {
        guard mediaCatalog != nil else { return true }
        guard isReady, !isShuttingDown else { return false }
        refreshAccessGrantsFromSources()
        let sourcePath = source.lastKnownURL.standardizedFileURL.path
        let grants = Dictionary(uniqueKeysWithValues: collection.accessGrants.map { ($0.id, $0) })
        for entry in collection.allEntries {
            let grant = entry.accessGrantID.flatMap { grants[$0] }
            let entryRootPath = URL(fileURLWithPath: entry.media.mediaItemID.rootPath).standardizedFileURL.path
            guard entryRootPath == sourcePath || grant?.sourcePath == sourcePath else { continue }
            guard let grant, CustomPlaylistCollection.isValidAccessGrant(grant) else { return false }
        }
        // An offline source cannot prove a live lease. Its durable bookmark is
        // the recovery authority, so keep the source until that Data is saved.
        return await flushPersistence()
    }

    func flushPersistence() async -> Bool {
        if lastPersistedCollection != collection, persistenceTask == nil { scheduleSave() }
        while let task = persistenceTask { await task.value }
        return lastPersistedCollection == collection && persistenceFailure == nil
    }

    private let store: any CustomPlaylistStoring
    private let resolutionIndexCache: MediaReferenceResolutionIndexCache
    private let detailProjectionCache: CustomPlaylistDetailProjectionCache
    private let reconcileOperation: ReconcileOperation
    private let grantCapture: GrantCapture?
    private let sourceGrantCapture: SourceGrantCapture?
    private let mediaResolver: (any CustomPlaylistMediaAccessResolving)?
    private let mediaCatalog: CustomPlaylistMediaCatalog?
    private var mediaCatalogObservation: AnyCancellable?
    @Published private var legacyMediaSnapshot = CustomPlaylistMediaCatalogSnapshot()
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
    private var lastPersistedCollection: CustomPlaylistCollection?
    private var isShuttingDown = false

    init(
        store: any CustomPlaylistStoring,
        reconcileOperation: @escaping ReconcileOperation = { collection, index in
            var updated = collection
            return try updated.reconcileCancellable(using: index) ? updated : nil
        },
        grantCapture: GrantCapture? = nil,
        sourceGrantCapture: SourceGrantCapture? = nil,
        resolver: (any CustomPlaylistMediaAccessResolving)? = nil
    ) {
        self.store = store
        self.reconcileOperation = reconcileOperation
        self.grantCapture = grantCapture
        self.sourceGrantCapture = sourceGrantCapture
        mediaResolver = resolver
        mediaCatalog = resolver.map(CustomPlaylistMediaCatalog.init)
        let resolutionIndexCache = MediaReferenceResolutionIndexCache()
        self.resolutionIndexCache = resolutionIndexCache
        detailProjectionCache = CustomPlaylistDetailProjectionCache(
            resolutionIndexCache: resolutionIndexCache
        )
        if let mediaCatalog {
            mediaCatalog.didResolve = { [weak self] resolution in
                self?.applyMediaResolution(resolution)
            }
            mediaCatalogObservation = mediaCatalog.$snapshot.dropFirst().sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
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
                lastPersistedCollection = collection
                self.replaceCollection(collection)
                loadingState = .ready
                if sourceGrantCapture != nil { refreshAccessGrantsFromSources() }
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
        await waitForMediaResolution()
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
    func createPlaylist(
        named name: String,
        items: [LibraryMediaItem] = []
    ) throws -> CustomPlaylist.ID {
        let grants = try capturedGrants(for: items, requireAll: true)
        return try mutate { collection in
            let id = try collection.createPlaylist(named: name)
            try collection.add(items: items, to: id, grantsByItemID: grants)
            return id
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
        let grants = try capturedGrants(for: items, requireAll: true)
        return try mutate { collection in
            try collection.add(items: items, to: playlistID, grantsByItemID: grants)
        }
    }

    func removeEntry(
        _ entryID: CustomPlaylistEntry.ID,
        from playlistID: CustomPlaylist.ID
    ) throws {
        try removeEntries([entryID], from: playlistID)
    }

    @discardableResult
    func removeEntries(
        _ entryIDs: Set<CustomPlaylistEntry.ID>,
        from playlistID: CustomPlaylist.ID
    ) throws -> Int {
        try mutate { collection in
            try collection.removeEntries(entryIDs, from: playlistID)
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
        if let mediaCatalog {
            if !contentIsUnchanged { backfillAccessGrants(using: items, index: index) }
            mediaCatalog.update(collection, force: !contentIsUnchanged)
            return
        }
        legacyMediaSnapshot = CustomPlaylistMediaCatalogSnapshot(
            items: items, revision: contentRevision ?? (legacyMediaSnapshot.revision &+ 1)
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
        await waitForMediaResolution()
    }

    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        collection requestedCollection: CustomPlaylistCollection? = nil,
        using items: [LibraryMediaItem],
        itemsRevision: UInt64? = nil
    ) -> [LibraryMediaItem] {
        if mediaCatalog != nil {
            return resolvedItems(in: playlistID, collection: requestedCollection)
        }
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
        if let mediaCatalog, let playlist = collection.playlist(id: playlistID) {
            let ids = Set(playlist.entries.map(\.id))
            return mediaCatalog.snapshot.itemsByEntryID.filter { ids.contains($0.key) }
        }
        return collection.resolvedItemsByEntryID(in: playlistID, using: items)
    }

    func detailSearchOperation(
        for playlist: CustomPlaylist,
        query: String,
        using items: [LibraryMediaItem],
        itemsRevision: UInt64
    ) -> LatestMediaSearch<CustomPlaylistDetailProjection>.Operation {
        if mediaCatalog != nil { return detailSearchOperation(for: playlist, query: query) }
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
        if let mediaCatalog {
            return CustomPlaylistDetailProjectionCache.makeProjection(
                search: MediaCollectionSearch(query: query),
                entries: MediaCollectionSearch(query: query).filteredEntries(from: playlist.entries),
                resolvedItemsByEntryID: mediaCatalog.snapshot.itemsByEntryID
            )
        }
        return detailProjectionCache.projection(
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
        await mediaCatalog?.shutdown()
        mediaCatalogObservation = nil
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
        updatedCollection.removeUnreferencedAccessGrants()
        guard updatedCollection.isValid else { throw CustomPlaylistStoreError.invalidCollection }
        guard updatedCollection != collection else {
            return result
        }
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
        if let mediaCatalog {
            mediaCatalog.update(collection)
        } else if schedulesReconciliation {
            scheduleReconciliation()
        }
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

    private func capturedGrants(
        for items: [LibraryMediaItem], requireAll: Bool
    ) throws -> [LibraryMediaItem.ID: CustomPlaylistMediaGrant] {
        try CustomPlaylistGrantBackfill.captureItems(items, requireAll: requireAll, capture: grantCapture)
    }

    private func backfillAccessGrants(
        using items: [LibraryMediaItem], index suppliedIndex: MediaReferenceResolutionIndex?
    ) {
        guard mediaCatalog != nil, !collection.allEntries.isEmpty else { return }
        do {
            let updated = try CustomPlaylistGrantBackfill.collection(
                byBackfilling: collection, items: items, index: suppliedIndex,
                itemCapture: grantCapture, sourceCapture: sourceGrantCapture
            )
            if updated != collection {
                replaceCollection(updated)
                scheduleSave()
            }
        } catch {
            // Removal barriers retain the source until a valid grant can be saved.
        }
    }

    private func applyMediaResolution(_ resolution: CustomPlaylistMediaResolution) {
        guard !isShuttingDown else { return }
        var updated = collection
        do {
            if try updated.applyMediaResolution(resolution) {
                guard updated.isValid else { return }
                replaceCollection(updated)
                scheduleSave()
            }
        } catch {
            persistenceFailure = .saveFailed
        }
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
                    lastPersistedCollection = collection
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
