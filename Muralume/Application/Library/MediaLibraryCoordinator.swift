import Combine
import Foundation

enum MediaLibraryScanState: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case failed(MediaLibraryScanFailure)
}

enum MediaLibraryStartDisposition: Equatable, Sendable {
    case scanStarted
    /// Includes anonymous legacy grants that remain retryable even though
    /// they are intentionally omitted from user-facing source warnings.
    case noRestorableRoots(hasTemporarilyUnavailableRoots: Bool)
    case alreadyStarted
}

enum MediaLibraryQueueRestoreResult: Equatable, Sendable {
    case restored
    case cancelled
    case temporarilyUnavailable
    case permanentlyUnavailable
}

enum MediaImportNotice: Hashable, Sendable {
    case partialFailure
    case failure
    case partialUnsupportedFileFormat
    case unsupportedFileFormat
    case selectedFolderContainsActiveFolder
    case activeFolderContainsSelectedFolder

    var localizedKey: String {
        switch self {
        case .partialFailure:
            "library.import.partial"
        case .failure:
            "library.import.failed"
        case .partialUnsupportedFileFormat:
            "library.import.unsupportedFormat.partial"
        case .unsupportedFileFormat:
            "library.import.unsupportedFormat"
        case .selectedFolderContainsActiveFolder:
            "library.import.folderContainsActiveFolder"
        case .activeFolderContainsSelectedFolder:
            "library.import.folderCoveredByActiveFolder"
        }
    }
}

struct MediaLibraryImportPreparation: Sendable {
    let generation: UInt64
    let acceptedEveryRequest: Bool
}

typealias RestoredPlaybackQueueShuffler = @MainActor (
    inout PlaybackQueue<LibraryMediaItem.ID>
) -> Void

@MainActor
final class MediaLibraryCoordinator: ObservableObject {
    /// Desktop playback installs these hooks so security-scoped media access
    /// remains open until independent display loads have fully unwound.
    var mediaItemsWillBeRemovedHandler:
        ((Set<LibraryMediaItem.ID>) async -> Void)?
    var prepareForMediaScopeShutdownHandler: (() async -> Void)?
    /// Resolved by the app composition root after named playlists have loaded.
    /// Keeping this as a provider avoids making the media library own playlist
    /// persistence while still allowing queue recovery to retain membership.
    var customPlaylistItemsProvider:
        ((CustomPlaylist.ID) -> [LibraryMediaItem]?)?

    private enum QueueChangeKind {
        case cursor
        case structure
    }

    private enum PlaybackQueueMembership: Equatable, Sendable {
        case mediaLibrary
        case customPlaylist(CustomPlaylist.ID)
        case fixed
        case external

        var playbackCollection: PlaybackCollection {
            switch self {
            case .mediaLibrary:
                .mediaLibrary
            case let .customPlaylist(id):
                .customPlaylist(id)
            case .fixed, .external:
                .fixed
            }
        }
    }

    private struct LoadTaskRecord {
        let itemID: LibraryMediaItem.ID
        let autoplay: Bool
        let task: Task<Void, Never>
    }

    private struct PlaybackProgressCheckpoint: Sendable {
        let itemID: LibraryMediaItem.ID
        let position: TimeInterval
        let duration: TimeInterval
    }

    private struct MediaPathDescriptor {
        let lexicalPathComponents: [String]
        let canonicalPathComponents: [String]
    }

    private struct MediaSourcePathDescriptor {
        let source: MediaSource
        let lexicalPathComponents: [String]
        let canonicalPathComponents: [String]

        func coverageMatch(
            for mediaPath: MediaPathDescriptor
        ) -> MediaSourceCoverageMatch? {
            // Lexical containment alone is unsafe when a descendant symlink
            // escapes an active folder. The resolved path must also remain
            // covered before that folder can own the item or its scope.
            guard covers(
                mediaPath.canonicalPathComponents,
                from: canonicalPathComponents
            ) else {
                return nil
            }
            if covers(
                mediaPath.lexicalPathComponents,
                from: lexicalPathComponents
            ) {
                return MediaSourceCoverageMatch(
                    source: source,
                    sourcePathComponents: lexicalPathComponents,
                    mediaPathComponents: mediaPath.lexicalPathComponents
                )
            }
            return MediaSourceCoverageMatch(
                source: source,
                sourcePathComponents: canonicalPathComponents,
                mediaPathComponents: mediaPath.canonicalPathComponents
            )
        }

        func covers(_ mediaPath: MediaPathDescriptor) -> Bool {
            coverageMatch(for: mediaPath) != nil
        }

        private func covers(
            _ mediaPathComponents: [String],
            from sourcePathComponents: [String]
        ) -> Bool {
            switch source.kind {
            case .file:
                mediaPathComponents == sourcePathComponents
            case .folder:
                mediaPathComponents.starts(with: sourcePathComponents)
            }
        }
    }

    private struct MediaSourceCoverageMatch {
        let source: MediaSource
        let sourcePathComponents: [String]
        let mediaPathComponents: [String]
    }

    private struct LexicalPathCoverageIndex {
        private let sourcePathComponents: [[String]]

        init<S: Sequence>(sourcePaths: S) where S.Element == String {
            sourcePathComponents = sourcePaths.map {
                Self.pathComponents(for: $0)
            }
        }

        func covers(mediaPathComponents: [String]) -> Bool {
            sourcePathComponents.contains {
                mediaPathComponents.starts(with: $0)
            }
        }

        static func pathComponents(for path: String) -> [String] {
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        }
    }

    /// Search projections use the revision as the identity of `items`.
    /// Publishing both fields together prevents a will-set observer from
    /// pairing a new revision with the previous collection.
    private struct ItemsSnapshot: Sendable {
        let revision: UInt64
        let contentRevision: UInt64
        let library: PreparedMediaLibraryItems

        var items: [LibraryMediaItem] { library.items }
        var resolutionIndex: MediaReferenceResolutionIndex { library.resolutionIndex }
        var rootURLsByPath: [String: URL] { library.rootURLsByPath }
        var temporaryPlaybackSnapshot: TemporaryPlaybackLibrarySnapshot {
            library.temporaryPlaybackSnapshot
        }
    }

    /// A session-local proof that manual selection already synchronized the
    /// whole visible library. Cursor movement preserves this proof; metadata,
    /// membership or structure updates invalidate it through their revisions.
    private struct LibraryQueueSynchronizationStamp: Equatable {
        let itemsRevision: UInt64
        let structureRevision: UInt64
        let metadataRevision: UInt64
    }

    private enum PublicationResult: Sendable {
        case applied(PublicationPruning)
        case retry(PreparedMediaLibrarySnapshot)
    }

    private struct PublicationPruning: Sendable {
        let itemIDs: Set<LibraryMediaItem.ID>
        let rootPaths: Set<String>
    }

    private struct PublicationStamp: Sendable {
        let itemsRevision: UInt64
        let queueStateRevision: UInt64
        let queueMetadataRevision: UInt64
        let unavailableRevision: UInt64
        let temporaryGeneration: UInt64
        let loadedItemID: LibraryMediaItem.ID?
        let membership: PlaybackQueueMembership
    }

    /// Keep superseded collections alive through the commit, so their final
    /// release runs on the bounded worker rather than the UI executor.
    private struct PublicationStorage: Sendable {
        let request: MediaLibraryPublicationRequest
        let previousSnapshot: ItemsSnapshot
        let previousItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
        let previousCanonicalIndex: MediaLibraryCanonicalLookupIndex?
    }

    private struct AppliedRootRemoval: Sendable {
        let removedItemIDs: Set<LibraryMediaItem.ID>
        let thumbnailRootIDs: Set<MediaLibraryRoot.ID>
        let supersededThumbnailRootPaths: Set<String>
        let removedCurrentItem: Bool
        let playbackTouched: Bool
        let shouldAutoplay: Bool
        let loadTasks: [Task<Void, Never>]
        let reloadItemID: LibraryMediaItem.ID?
        let reloadGeneration: UInt64
    }

    private struct RemovalStorage: Sendable {
        let request: MediaLibraryRemovalRequest
        let previousSnapshot: ItemsSnapshot
        let previousItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
        let previousCanonicalIndex: MediaLibraryCanonicalLookupIndex?
    }

    @Published private(set) var scanState: MediaLibraryScanState = .idle
    @Published private(set) var roots: [MediaLibraryRoot] = []
    @Published private var itemsSnapshot = ItemsSnapshot(
        revision: 0,
        contentRevision: 0,
        library: PreparedMediaLibraryItems(
            items: [], itemsByID: [:],
            resolutionIndex: MediaReferenceResolutionIndex(items: []),
            rootURLsByPath: [:], temporaryPlaybackSnapshot: .empty
        )
    )
    @Published private(set) var playbackOrder: PlaybackOrder
    @Published private(set) var playbackRepeatBehavior:
        PlaybackRepeatBehavior
    @Published private(set) var sort: MediaLibrarySort
    @Published private(set) var currentItemID: LibraryMediaItem.ID?
    @Published private(set) var unavailableItemIDs:
        Set<LibraryMediaItem.ID> = []
    private(set) var unavailableItemsRevision: UInt64 = 0
    @Published private(set) var queueRevision: UInt64 = 0
    @Published private(set) var queueStructureRevision: UInt64 = 0
    private(set) var queueStateRevision: UInt64 = 0
    /// Explicit selections can return to the same item (ABA); cursor identity
    /// alone cannot protect an asynchronous import's older playback intent.
    private(set) var playbackSelectionIntentRevision: UInt64 = 0
    @Published private(set) var importNotice: MediaImportNotice?
    @Published private(set) var externalPlaybackNotice:
        ExternalPlaybackNotice?
    @Published private(set) var isExternalPlaybackContext = false
    @Published private(set) var temporaryItemIDs:
        Set<LibraryMediaItem.ID> = []
    @Published private(set) var sourceAccessState:
        MediaLibrarySourceAccessState = .empty
    @Published private(set) var unavailableSources:
        [UnavailableMediaSource] = []
    /// The authoritative set used by coarse filesystem monitoring. Explicit
    /// file imports are deliberately excluded because FSEvents monitoring is
    /// recursive-folder based.
    @Published private(set) var monitoredFolderURLs: [URL] = []

    var items: [LibraryMediaItem] {
        itemsSnapshot.items
    }

    var itemsRevision: UInt64 {
        itemsSnapshot.revision
    }

    var itemsContentRevision: UInt64 { itemsSnapshot.contentRevision }

    var libraryItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] { visibleItemsByID }

    var mediaReferenceResolutionIndex: MediaReferenceResolutionIndex {
        itemsSnapshot.resolutionIndex
    }

    var itemsPublisher: AnyPublisher<[LibraryMediaItem], Never> {
        $itemsSnapshot
            .map(\.items)
            .eraseToAnyPublisher()
    }

    var itemsRevisionPublisher:
        AnyPublisher<(items: [LibraryMediaItem], revision: UInt64), Never> {
        $itemsSnapshot.map { (items: $0.items, revision: $0.revision) }
            .eraseToAnyPublisher()
    }

    var itemsContentRevisionPublisher: AnyPublisher<(
        items: [LibraryMediaItem], revision: UInt64, contentRevision: UInt64,
        resolutionIndex: MediaReferenceResolutionIndex
    ), Never> {
        $itemsSnapshot.map {
            (items: $0.items, revision: $0.revision,
             contentRevision: $0.contentRevision, resolutionIndex: $0.resolutionIndex)
        }.eraseToAnyPublisher()
    }

    var currentItem: LibraryMediaItem? {
        guard let currentItemID else {
            return nil
        }
        return queueItemsByID[currentItemID]
            ?? visibleItemsByID[currentItemID]
    }

    func libraryItem(matching url: URL) async -> LibraryMediaItem? {
        guard url.isFileURL else {
            return nil
        }
        return try? await firstItemAsync(matching: [url])
    }

    func mediaItem(
        forPersistedID id: LibraryMediaItem.ID
    ) -> LibraryMediaItem? {
        visibleItemsByID[id]
    }

    var currentPosition: Int? {
        queue?.currentRoundPosition
    }

    var queueCount: Int {
        queue?.count ?? 0
    }

    var recentlyPlayedItems: [LibraryMediaItem] {
        recentlyPlayedItems(limit: .max)
    }

    func recentlyPlayedItems(limit: Int) -> [LibraryMediaItem] {
        guard let queue else {
            return []
        }
        return queue.recentHistoryItems(limit: limit).reversed().compactMap {
            queueItemsByID[$0]
        }
    }

    var upNextItems: [LibraryMediaItem] {
        upNextItems(limit: .max)
    }

    var upNextItemCount: Int {
        queue?.upNextCount ?? 0
    }

    func upNextItems(limit: Int) -> [LibraryMediaItem] {
        guard let queue else {
            return []
        }
        return queue.upNextItems(limit: limit).compactMap {
            queueItemsByID[$0]
        }
    }

    var hasActiveQueue: Bool {
        queue != nil
    }

    var activePlaybackCollection: PlaybackCollection {
        playbackQueueMembership.playbackCollection
    }

    var activeQueueMediaReferences: [MediaReference] {
        guard let queue else {
            return []
        }
        return queue.items.compactMap { itemID in
            queueItemsByID[itemID].map(MediaReference.init(item:))
        }
    }

    var isTemporaryPlayback: Bool {
        !temporaryItemIDs.isEmpty
    }

    var playbackMode: PlaybackMode {
        PlaybackMode(
            order: playbackOrder,
            repeatBehavior: playbackRepeatBehavior
        )
    }

#if DEBUG
    var queueHistoryStorageIdentityForTesting: UInt? {
        queue?.historyStorageIdentityForTesting
    }

    private(set) var canonicalItemLookupIndexBuildCountForTesting = 0

    var canonicalLookupRootCountForTesting: Int {
        canonicalItemLookupIndex?.rootResolutions.count ?? 0
    }
#endif

    var canRefresh: Bool {
        !isShutDown
            && !activeSources.isEmpty
            && rootIDsPendingRemoval.isEmpty
            && scanState != .scanning
    }

    var canRetrySourceAccess: Bool {
        !isShutDown
            && rootIDsPendingRemoval.isEmpty
            && scanState != .scanning
            && (
                sourceAccessState.hasUnavailableSources
                    || mediaSession.hasUnavailablePersistedSources
            )
    }

    var canMoveToPrevious: Bool {
        queue?.canMoveToPrevious == true
    }

    var canMoveToNext: Bool {
        queue?.canMoveToNext == true
    }

    private let playback: PlaybackCoordinator
    private let sourceSelector: any MediaSourceSelecting
    private let mediaSession: any MediaAccessSession
    private let scanner: any MediaLibraryScanning
    private let mediaThumbnailProvider: any MediaThumbnailProviding
    private let snapshotPreparer: any MediaLibrarySnapshotPreparing
    private let removalPreparer: any MediaLibraryRemovalPreparing
    private let preferencesStore: (any AppPreferencesStoring)?
    private let playbackProgressStore: (any PlaybackProgressStoring)?
    private let reshuffleRestoredQueue: RestoredPlaybackQueueShuffler?
    private let canonicalLookup: MediaLibraryCanonicalLookup
    private let canonicalLookupPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1, maximumQueuedWorkCount: 256
    )
    private let queueRestorationPreparer: any MediaLibraryQueueRestorationPreparing
    private let queueRestorationPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1, maximumQueuedWorkCount: 1
    )
    private var queueRestorationTask: Task<MediaLibraryQueueRestorePreparation, Error>?
    private var queueRestorationGeneration: UInt64 = 0
    private let temporaryPlaybackSession: TemporaryPlaybackSession

    private var activeSources: [MediaSource] = []
    private var incompleteRootPaths: Set<String> = []
    private var visibleItemsByID: [
        LibraryMediaItem.ID: LibraryMediaItem
    ] = [:]
    private var canonicalItemLookupIndex: MediaLibraryCanonicalLookupIndex?
    private var cachedQueueSnapshot:
        PlaybackQueueSnapshot<LibraryMediaItem.ID>?
    private var queue: PlaybackQueue<LibraryMediaItem.ID>? {
        didSet {
            queueStateRevision &+= 1
            cachedQueueSnapshot = nil
        }
    }
    // Queue membership and persistence freezing are independent: a Finder
    // detour from dynamic desktop can use the full library while saves pause.
    private var playbackQueueMembership: PlaybackQueueMembership =
        .mediaLibrary
    private var libraryQueueSynchronizationStamp: LibraryQueueSynchronizationStamp?
    private var queueMetadataRevision: UInt64 = 0
    private var queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:] {
        didSet { queueMetadataRevision &+= 1 }
    }
    private let publicationWorkPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1, maximumQueuedWorkCount: 1
    )
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private let scanWorkPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1,
        maximumQueuedWorkCount: 1
    )
    private var lastPublishedScanSourcePaths: Set<String> = []
    private var lastPublishedScanSort: MediaLibrarySort?
    private var lastPublishedScanMembership: PlaybackQueueMembership?
    private var lastPublishedScanItemsRevision: UInt64 = 0
    private var lastPublishedScanQueueStructureRevision: UInt64 = 0
    private var currentScanTaskID: UUID?
    private var currentScanSourcePaths: Set<String>?
    private var sortTasks: [UUID: Task<Void, Never>] = [:]
    private var currentSortTaskID: UUID?
    private var loadTasks: [UUID: LoadTaskRecord] = [:]
    private var currentLoadTaskID: UUID?
    private var loadedItemID: LibraryMediaItem.ID?
    private var rootIDsPendingRemoval: Set<MediaLibraryRoot.ID> = []
    private var rootRemovalTasks: [MediaLibraryRoot.ID: Task<Void, Never>] = [:]
    private var rootRemovalPreparationTasks:
        [MediaLibraryRoot.ID: Task<AppliedRootRemoval?, Error>] = [:]
    private let removalWorkPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1, maximumQueuedWorkCount: 1
    )
    private var scanGeneration: UInt64 = 0
    private var sortGeneration: UInt64 = 0
    private var importGeneration: UInt64 = 0
    private var lastCommittedImportGeneration: UInt64 = 0
    private var explicitPlayIntentGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var latestPreparedSources: [MediaSource] = []
    private var preparedSourcesNeedRefresh = false
    private var pendingExplicitFileURLs: [URL] = []
    private var pendingAutoplayFileURLs: [URL] = []
    private var pendingExplicitImportNeedsQueueExpansion = false
    private var supersededThumbnailRootPaths: Set<String> = []
    private var hasStarted = false
    private var isShutDown = false
    private var temporaryPlaybackGeneration: UInt64 = 0
    private var sourceAccessOperationGeneration: UInt64 = 0

    init(
        playback: PlaybackCoordinator,
        sourceSelector: any MediaSourceSelecting,
        mediaSession: any MediaAccessSession,
        scanner: any MediaLibraryScanning,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        snapshotPreparer: any MediaLibrarySnapshotPreparing =
            DefaultMediaLibrarySnapshotPreparer(),
        playbackOrder: PlaybackOrder,
        playbackRepeatBehavior: PlaybackRepeatBehavior = .queue,
        sort: MediaLibrarySort = MediaLibrarySort(),
        preferencesStore: (any AppPreferencesStoring)? = nil,
        playbackProgressStore: (any PlaybackProgressStoring)? = nil,
        reshuffleRestoredQueue: RestoredPlaybackQueueShuffler? = nil,
        queueRestorationPreparer: any MediaLibraryQueueRestorationPreparing =
            DefaultMediaLibraryQueueRestorationPreparer(),
        canonicalLookup: MediaLibraryCanonicalLookup = MediaLibraryCanonicalLookup(),
        removalPreparer: any MediaLibraryRemovalPreparing =
            DefaultMediaLibraryRemovalPreparer()
    ) {
        self.playback = playback
        self.sourceSelector = sourceSelector
        self.mediaSession = mediaSession
        self.scanner = scanner
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.snapshotPreparer = snapshotPreparer
        self.removalPreparer = removalPreparer
        temporaryPlaybackSession = TemporaryPlaybackSession(
            scanner: scanner
        )
        self.playbackOrder = playbackOrder
        self.playbackRepeatBehavior = playbackRepeatBehavior
        self.sort = sort
        self.preferencesStore = preferencesStore
        self.playbackProgressStore = playbackProgressStore
        self.reshuffleRestoredQueue = reshuffleRestoredQueue
        self.queueRestorationPreparer = queueRestorationPreparer
        self.canonicalLookup = canonicalLookup

        playback.itemEndedHandler = { [weak self] in
            self?.handleItemEnded() ?? .unhandled
        }
        playback.itemFailureHandler = { [weak self] _ in
            self?.handleItemFailure() ?? false
        }
    }

    @discardableResult
    func start() -> MediaLibraryStartDisposition {
        guard let operationGeneration = beginStartup() else {
            return .alreadyStarted
        }
        return finishStartup(
            with: mediaSession.restoreSources(),
            operationGeneration: operationGeneration
        )
    }

    @discardableResult
    func startAsync() async -> MediaLibraryStartDisposition {
        guard let operationGeneration = beginStartup() else {
            return .alreadyStarted
        }
        let restoredSources = await mediaSession.restoreSourcesAsync()
        guard isCurrentSourceAccessOperation(operationGeneration) else {
            return .alreadyStarted
        }
        if Task.isCancelled {
            recordDeferredStartupSources(restoredSources)
            return .alreadyStarted
        }
        return finishStartup(
            with: restoredSources,
            operationGeneration: operationGeneration
        )
    }

    private func beginStartup() -> UInt64? {
        guard !hasStarted, !isShutDown else {
            return nil
        }
        hasStarted = true
        return beginSourceAccessOperation()
    }

    private func finishStartup(
        with restoredSources: [MediaSource],
        operationGeneration: UInt64
    ) -> MediaLibraryStartDisposition {
        guard isCurrentSourceAccessOperation(operationGeneration) else {
            return .alreadyStarted
        }
        // Publish monitored folders before the startup scan begins so a
        // filesystem change cannot fall into a scan/watch installation gap.
        installActiveSources(restoredSources)
        updateSourceAccessState(using: restoredSources)
        guard !restoredSources.isEmpty else {
            scanState = .idle
            return .noRestorableRoots(
                hasTemporarilyUnavailableRoots:
                    mediaSession.hasUnavailablePersistedSources
            )
        }
        latestPreparedSources = restoredSources
        refresh(using: restoredSources)
        return .scanStarted
    }

    private func recordDeferredStartupSources(
        _ restoredSources: [MediaSource]
    ) {
        // Cancellation suppresses publication and scanning so a close or
        // external-open intent stays authoritative. Keep only source-access
        // bookkeeping: start is one-shot, and dropping this state would make
        // unavailable bookmarks impossible to retry after reopening.
        installActiveSources(restoredSources)
        latestPreparedSources = restoredSources
        preparedSourcesNeedRefresh = !restoredSources.isEmpty
        updateSourceAccessState(using: restoredSources)
    }

    func waitForStartupScan(
        after disposition: MediaLibraryStartDisposition
    ) async -> MediaLibraryScanState {
        switch disposition {
        case .noRestorableRoots:
            return .idle
        case .alreadyStarted where scanState != .scanning:
            return scanState
        case .scanStarted, .alreadyStarted:
            break
        }

        for await state in $scanState.values {
            if Task.isCancelled {
                return scanState
            }
            if state != .scanning {
                return state
            }
        }
        return scanState
    }

    func addMedia() {
        selectMediaSources(
            intent: .addingMedia,
            autoplayExplicitFiles: true
        )
    }

    @discardableResult
    func reauthorizeMediaSources() -> MediaLibraryStartDisposition? {
        selectMediaSources(
            intent: .reauthorizingSources,
            autoplayExplicitFiles: false
        )
    }

    @discardableResult
    func reauthorizeMediaSource(
        _ source: UnavailableMediaSource
    ) -> MediaLibraryStartDisposition? {
        guard unavailableSources.contains(where: { $0.id == source.id }) else {
            return nil
        }
        guard let preparation = selectMediaSourcesForPreparation(
            intent: .reauthorizingSource(source)
        ) else {
            return nil
        }
        mediaSession.removeUnavailableSource(source)
        updateSourceAccessState(using: latestPreparedSources)
        commitImport(preparation, autoplayExplicitFiles: false)
        return scanState == .scanning ? .scanStarted : .alreadyStarted
    }

    func removeUnavailableSource(_ source: UnavailableMediaSource) {
        guard !isShutDown,
              rootIDsPendingRemoval.isEmpty,
              unavailableSources.contains(where: { $0.id == source.id }) else {
            return
        }
        mediaSession.removeUnavailableSource(source)
        updateSourceAccessState(using: activeSources)
        guard let playbackProgressStore else {
            return
        }
        let rootPath = source.lastKnownURL.standardizedFileURL.path
        Task {
            try? await playbackProgressStore.pruneProgress(
                keeping: [],
                withinRootPaths: [rootPath]
            )
        }
    }

    func unavailableSource(
        for item: LibraryMediaItem
    ) -> UnavailableMediaSource? {
        let rootPath = item.rootURL.standardizedFileURL.path
        return unavailableSources.first {
            $0.lastKnownURL.standardizedFileURL.path == rootPath
        }
    }

    @discardableResult
    private func selectMediaSources(
        intent: MediaSourceSelectionIntent,
        autoplayExplicitFiles: Bool
    ) -> MediaLibraryStartDisposition? {
        guard let preparation = selectMediaSourcesForPreparation(
            intent: intent
        ) else {
            return nil
        }
        commitImport(
            preparation,
            autoplayExplicitFiles: autoplayExplicitFiles
        )
        return scanState == .scanning ? .scanStarted : .alreadyStarted
    }

    private func selectMediaSourcesForPreparation(
        intent: MediaSourceSelectionIntent
    ) -> MediaLibraryImportPreparation? {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return nil
        }
        let selectedURLs = sourceSelector.selectSources(for: intent)
        return prepareImport(selectedURLs)
    }

    @discardableResult
    func retryUnavailableSourceAccess() -> MediaLibraryStartDisposition {
        guard canRetrySourceAccess else {
            return .alreadyStarted
        }

        let operationGeneration = beginSourceAccessOperation()
        let previousSources = activeSources
        let previousSourcePaths = sourcePathSet(previousSources)
        let restoredSources = mediaSession.retryUnavailableSources()
        guard isCurrentSourceAccessOperation(operationGeneration) else {
            return .alreadyStarted
        }
        recordSupersededThumbnailRoots(
            previousSources: previousSources,
            activeSources: restoredSources
        )
        latestPreparedSources = restoredSources
        updateSourceAccessState(using: restoredSources)

        guard sourcePathSet(restoredSources) != previousSourcePaths,
              !restoredSources.isEmpty else {
            if restoredSources.isEmpty {
                return .noRestorableRoots(
                    hasTemporarilyUnavailableRoots:
                        mediaSession.hasUnavailablePersistedSources
                )
            }
            return .alreadyStarted
        }
        preparedSourcesNeedRefresh = true
        refresh(using: restoredSources)
        return .scanStarted
    }

    @discardableResult
    func retryUnavailableSourceAccessAsync() async
        -> MediaLibraryStartDisposition {
        guard canRetrySourceAccess else {
            return .alreadyStarted
        }

        let operationGeneration = beginSourceAccessOperation()
        let previousSources = activeSources
        let previousSourcePaths = sourcePathSet(previousSources)
        let restoredSources = await mediaSession.retryUnavailableSourcesAsync()
        guard !Task.isCancelled,
              isCurrentSourceAccessOperation(operationGeneration) else {
            return .alreadyStarted
        }
        recordSupersededThumbnailRoots(
            previousSources: previousSources,
            activeSources: restoredSources
        )
        latestPreparedSources = restoredSources
        updateSourceAccessState(using: restoredSources)

        guard sourcePathSet(restoredSources) != previousSourcePaths,
              !restoredSources.isEmpty else {
            if restoredSources.isEmpty {
                return .noRestorableRoots(
                    hasTemporarilyUnavailableRoots:
                        mediaSession.hasUnavailablePersistedSources
                )
            }
            return .alreadyStarted
        }

        preparedSourcesNeedRefresh = true
        refresh(using: restoredSources)
        return .scanStarted
    }

    func prepareImport(
        _ selectedURLs: [URL],
        incomingScopePolicy: MediaAccessIncomingScopePolicy = .sessionManaged
    ) -> MediaLibraryImportPreparation? {
        guard !isShutDown,
              rootIDsPendingRemoval.isEmpty,
              !selectedURLs.isEmpty else {
            return nil
        }
        invalidateSourceAccessOperation()

        let previouslyPreparedSources = latestPreparedSources.isEmpty
            ? activeSources
            : latestPreparedSources
        let update = mediaSession.addSources(
            selectedURLs,
            incomingScopePolicy: incomingScopePolicy
        )
        return finishImportPreparation(
            update, previouslyPreparedSources: previouslyPreparedSources
        )
    }

    var supportsAsynchronousImportPreparation: Bool {
        mediaSession.supportsAsynchronousImportPreparation
    }

    func prepareImportAsync(
        _ selectedURLs: [URL],
        incomingScopePolicy: MediaAccessIncomingScopePolicy = .sessionManaged
    ) async -> MediaLibraryImportPreparation? {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty,
              !selectedURLs.isEmpty else { return nil }
        let operationGeneration = beginSourceAccessOperation()
        let previousSources = latestPreparedSources.isEmpty
            ? activeSources : latestPreparedSources
        let update = await mediaSession.addSourcesAsync(
            selectedURLs, incomingScopePolicy: incomingScopePolicy
        )
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else { return nil }
        let requestedFileMatches: [LibraryMediaItem?]?
        do {
            if !Task.isCancelled, isCurrentSourceAccessOperation(operationGeneration) {
                requestedFileMatches = try await itemsAsync(
                    matching: update.requestedFileURLs,
                    sourceURLs: update.activeSources.map(\.url)
                )
            } else { requestedFileMatches = nil }
        } catch { requestedFileMatches = nil }
        guard !Task.isCancelled, requestedFileMatches != nil,
              isCurrentSourceAccessOperation(operationGeneration) else {
            // A cancelled batch may already have durably accepted a prefix.
            // Keep those grants visible without reviving its stale play intent.
            let sources = mediaSession.restoreSources()
            recordSupersededThumbnailRoots(
                previousSources: latestPreparedSources,
                activeSources: sources
            )
            latestPreparedSources = sources
            preparedSourcesNeedRefresh = preparedSourcesNeedRefresh
                || update.didChangeSources
            installActiveSources(sources)
            updateSourceAccessState(using: sources)
            if preparedSourcesNeedRefresh, !sources.isEmpty,
               !isCurrentScanTargeting(sources) {
                refresh(
                    using: sources,
                    candidateFileURLs: pendingExplicitFileURLs,
                    autoplayFileURLs: pendingAutoplayFileURLs,
                    explicitIntentGeneration: pendingAutoplayFileURLs.isEmpty
                        ? nil : explicitPlayIntentGeneration,
                    expandQueueForExplicitImport:
                        pendingExplicitImportNeedsQueueExpansion,
                    importGeneration: importGeneration
                )
            }
            return nil
        }
        return finishImportPreparation(
            update, previouslyPreparedSources: previousSources,
            requestedFileMatches: requestedFileMatches
        )
    }

    private func finishImportPreparation(
        _ update: MediaAccessUpdate,
        previouslyPreparedSources: [MediaSource],
        requestedFileMatches preparedMatches: [LibraryMediaItem?]? = nil
    ) -> MediaLibraryImportPreparation? {
        if update.acceptedRequestCount == 0 {
            importNotice = switch update.exclusiveRejectionReason {
            case .unsupportedFileFormat:
                .unsupportedFileFormat
            case .selectedFolderContainsActiveFolder:
                .selectedFolderContainsActiveFolder
            case .activeFolderContainsSelectedFolder:
                .activeFolderContainsSelectedFolder
            case nil:
                .failure
            }
            return nil
        }
        if update.rejectedRequestCount == 0 {
            importNotice = nil
        } else if update.actionableRejectionCounts[
            .unsupportedFileFormat
        ] == update.rejectedRequestCount {
            importNotice = .partialUnsupportedFileFormat
        } else {
            importNotice = .partialFailure
        }

        let requestedFileURLs = update.requestedFileURLs
        recordSupersededThumbnailRoots(
            previousSources: previouslyPreparedSources,
            activeSources: update.activeSources
        )
        latestPreparedSources = update.activeSources
        updateSourceAccessState(using: update.activeSources)
        preparedSourcesNeedRefresh =
            preparedSourcesNeedRefresh || update.didChangeSources
        if !requestedFileURLs.isEmpty {
            let requestedFileMatches = preparedMatches ?? items(matching: requestedFileURLs)
            pendingExplicitImportNeedsQueueExpansion =
                pendingExplicitImportNeedsQueueExpansion
                    || requestedFileMatches.contains {
                        $0 == nil
                    }
            appendPendingExplicitFiles(requestedFileURLs)
            pendingAutoplayFileURLs = requestedFileURLs
            explicitPlayIntentGeneration &+= 1
        }
        guard update.didChangeSources || !requestedFileURLs.isEmpty else {
            return nil
        }

        importGeneration &+= 1
        return MediaLibraryImportPreparation(
            generation: importGeneration,
            acceptedEveryRequest: update.rejectedRequestCount == 0
        )
    }

    func addMediaAsync(
        shouldAutoplayProvider: @escaping @MainActor () -> Bool = { true }
    ) async {
        _ = await selectMediaSourcesAsync(
            intent: .addingMedia,
            autoplay: true,
            shouldAutoplayProvider: shouldAutoplayProvider
        )
    }

    func reauthorizeMediaSourcesAsync() async -> MediaLibraryStartDisposition? {
        await selectMediaSourcesAsync(intent: .reauthorizingSources, autoplay: false)
    }

    func reauthorizeMediaSourceAsync(
        _ source: UnavailableMediaSource
    ) async -> MediaLibraryStartDisposition? {
        guard unavailableSources.contains(where: { $0.id == source.id }) else {
            return nil
        }
        guard let disposition = await selectMediaSourcesAsync(
            intent: .reauthorizingSource(source), autoplay: false
        ) else { return nil }
        mediaSession.removeUnavailableSource(source)
        updateSourceAccessState(using: latestPreparedSources)
        return disposition
    }

    private func selectMediaSourcesAsync(
        intent: MediaSourceSelectionIntent,
        autoplay: Bool,
        shouldAutoplayProvider: @MainActor () -> Bool = { true }
    ) async -> MediaLibraryStartDisposition? {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else { return nil }
        let urls = sourceSelector.selectSources(for: intent)
        guard let preparation = await prepareImportAsync(urls) else { return nil }
        await commitImportAsync(
            preparation, autoplayExplicitFiles: autoplay,
            shouldAutoplayProvider: shouldAutoplayProvider
        )
        return scanState == .scanning ? .scanStarted : .alreadyStarted
    }

    func commitImportAsync(
        _ preparation: MediaLibraryImportPreparation,
        autoplayExplicitFiles: Bool = true,
        shouldAutoplayProvider: @MainActor () -> Bool = { true }
    ) async {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty,
              preparation.generation == importGeneration,
              preparation.generation > lastCommittedImportGeneration else { return }
        let selectionRevision = playbackSelectionIntentRevision
        let explicitURLs = pendingExplicitFileURLs
        let autoplayURLs = pendingAutoplayFileURLs
        let matches: [LibraryMediaItem?]
        let autoplayItem: LibraryMediaItem?
        do {
            if autoplayExplicitFiles {
                let allMatches = try await itemsAsync(
                    matching: explicitURLs + autoplayURLs,
                    sourceURLs: latestPreparedSources.map(\.url)
                )
                matches = Array(allMatches.prefix(explicitURLs.count))
                autoplayItem = allMatches.dropFirst(explicitURLs.count).compactMap { $0 }.first
            } else {
                matches = []
                autoplayItem = nil
            }
        } catch { return }
        guard !Task.isCancelled else { return }
        commitImport(
            preparation,
            autoplayExplicitFiles: autoplayExplicitFiles
                && selectionRevision == playbackSelectionIntentRevision
                && shouldAutoplayProvider(),
            preparedMatches: matches, preparedAutoplayItem: autoplayItem
        )
    }

    /// Compatibility entry point for synchronous source selectors. Live
    /// filesystem-backed sessions prepare and commit through the async path.
    func commitImport(
        _ preparation: MediaLibraryImportPreparation,
        autoplayExplicitFiles: Bool = true
    ) {
        commitImport(preparation, autoplayExplicitFiles: autoplayExplicitFiles,
                     preparedMatches: nil, preparedAutoplayItem: nil)
    }

    private func commitImport(
        _ preparation: MediaLibraryImportPreparation,
        autoplayExplicitFiles: Bool,
        preparedMatches: [LibraryMediaItem?]?,
        preparedAutoplayItem: LibraryMediaItem?
    ) {
        guard !isShutDown,
              rootIDsPendingRemoval.isEmpty,
              preparation.generation == importGeneration,
              preparation.generation > lastCommittedImportGeneration else {
            return
        }
        lastCommittedImportGeneration = preparation.generation

        let committedGeneration = importGeneration
        let sources = latestPreparedSources
        let explicitFileURLs = pendingExplicitFileURLs
        let playIntentGeneration = explicitPlayIntentGeneration
        let needsQueueExpansion = pendingExplicitImportNeedsQueueExpansion

        guard autoplayExplicitFiles else {
            clearPendingExplicitImport(
                matching: playIntentGeneration
            )
            if preparedSourcesNeedRefresh,
               !isCurrentScanTargeting(sources) {
                refresh(using: sources)
            }
            return
        }

        let explicitFileMatches = preparedMatches ?? items(matching: explicitFileURLs)
        let everyExplicitFileIsVisible = !explicitFileURLs.isEmpty
            && explicitFileMatches.allSatisfy { $0 != nil }
        let autoplayItem = preparedMatches != nil
            ? preparedAutoplayItem : firstItem(matching: pendingAutoplayFileURLs)
        if everyExplicitFileIsVisible, let existingItem = autoplayItem {
            activateImportedItem(
                existingItem,
                expandQueue: needsQueueExpansion
            )
            clearPendingExplicitImport(
                matching: playIntentGeneration
            )
            if preparedSourcesNeedRefresh,
               !isCurrentScanTargeting(sources) {
                refresh(using: sources)
            }
            return
        }

        guard preparedSourcesNeedRefresh || !explicitFileURLs.isEmpty else {
            return
        }
        refresh(
            using: sources,
            candidateFileURLs: explicitFileURLs,
            autoplayFileURLs: pendingAutoplayFileURLs,
            explicitIntentGeneration: playIntentGeneration,
            expandQueueForExplicitImport: needsQueueExpansion,
            importGeneration: committedGeneration
        )
    }

    func dismissImportNotice() {
        importNotice = nil
    }

    func dismissExternalPlaybackNotice() {
        externalPlaybackNotice = nil
    }

    var currentItemIsTemporary: Bool {
        currentItemID.map(temporaryItemIDs.contains) == true
    }

    @discardableResult
    func addCurrentTemporaryItemToLibrary() -> Bool {
        guard currentItemIsTemporary,
              let item = currentItem,
              let preparation = prepareImport(
                [item.url],
                incomingScopePolicy: .callerManaged
              ) else {
            return false
        }
        commitImport(preparation)
        return true
    }

    @discardableResult
    func addCurrentTemporaryItemToLibraryAsync() async -> Bool {
        guard currentItemIsTemporary, let item = currentItem else { return false }
        let selectionRevision = playbackSelectionIntentRevision
        guard let preparation = await prepareImportAsync(
                [item.url], incomingScopePolicy: .callerManaged
              ) else { return false }
        await commitImportAsync(
            preparation,
            shouldAutoplayProvider: {
                selectionRevision == self.playbackSelectionIntentRevision
                    && !self.playback.isPlayerWindowDismissed
            }
        )
        return true
    }

    @discardableResult
    func addTemporaryItemsToLibraryAsync() async -> Bool {
        guard !temporaryItemIDs.isEmpty else { return true }
        let urls = queue?.items.compactMap { id in
            temporaryItemIDs.contains(id) ? queueItemsByID[id]?.url : nil
        } ?? []
        guard !urls.isEmpty,
              let preparation = await prepareImportAsync(
                urls, incomingScopePolicy: .callerManaged
              ) else { return false }
        await commitImportAsync(preparation, autoplayExplicitFiles: false)
        return preparation.acceptedEveryRequest
    }

    @discardableResult
    func addTemporaryItemsToLibrary() -> Bool {
        guard !temporaryItemIDs.isEmpty else {
            return true
        }
        let temporaryURLs: [URL] = queue?.items.compactMap { itemID in
            guard temporaryItemIDs.contains(itemID) else {
                return nil
            }
            return queueItemsByID[itemID]?.url
        } ?? []
        guard !temporaryURLs.isEmpty,
              let preparation = prepareImport(
                temporaryURLs,
                incomingScopePolicy: .callerManaged
              ) else {
            return false
        }
        let activeSourceDescriptors = sourcePathDescriptors(
            for: latestPreparedSources
        )
        let didAcceptEveryTemporaryItem = temporaryURLs.allSatisfy { url in
            let mediaPath = mediaPathDescriptor(for: url)
            return activeSourceDescriptors.contains {
                $0.covers(mediaPath)
            }
        }

        // Persist the whole external queue without changing which item is
        // currently playing. The subsequent library scan promotes matching
        // queue items from temporary URLs to persistent sources.
        commitImport(preparation, autoplayExplicitFiles: false)
        return didAcceptEveryTemporaryItem
    }

    func adoptExternalPlaybackContext() {
        guard isExternalPlaybackContext else {
            return
        }
        temporaryPlaybackGeneration &+= 1
        temporaryPlaybackSession.end()
        isExternalPlaybackContext = false
        playbackQueueMembership = .mediaLibrary
        externalPlaybackNotice = nil
        // The queue itself is unchanged, but it is now eligible for normal
        // session and dynamic-desktop persistence.
        publishQueueChange(.cursor)
    }

    func beginExternalPlaybackContext() {
        guard !isShutDown else {
            return
        }
        // Supersede an in-flight restore immediately. The active temporary
        // scopes stay alive until the replacement request resolves or a
        // library selection explicitly ends them.
        temporaryPlaybackGeneration &+= 1
        isExternalPlaybackContext = true
    }

    func playLibraryItem(
        _ item: LibraryMediaItem,
        preservingExternalContext: Bool = false
    ) {
        guard let libraryItem = visibleItemsByID[item.id] else {
            return
        }
        playbackSelectionIntentRevision &+= 1
        // A library selection supersedes any unresolved Finder request even
        // when that request has not installed an external queue yet.
        temporaryPlaybackGeneration &+= 1
        temporaryPlaybackSession.end()
        temporaryItemIDs.removeAll()
        externalPlaybackNotice = nil

        let endedExternalPlaybackContext =
            isExternalPlaybackContext && !preservingExternalContext
        if endedExternalPlaybackContext {
            isExternalPlaybackContext = false
        }
        play(
            libraryItem,
            queueMembership: .mediaLibrary,
            collectionItems: items
        )
        if endedExternalPlaybackContext {
            publishQueueChange(.cursor)
        }
    }

    func playCustomPlaylistItem(
        _ item: LibraryMediaItem,
        playlistID: CustomPlaylist.ID,
        playlistItems: [LibraryMediaItem]
    ) {
        guard visibleItemsByID[item.id] != nil,
              playlistItems.contains(where: { $0.id == item.id }) else {
            return
        }
        playbackSelectionIntentRevision &+= 1
        temporaryPlaybackGeneration &+= 1
        temporaryPlaybackSession.end()
        temporaryItemIDs.removeAll()
        externalPlaybackNotice = nil
        isExternalPlaybackContext = false
        play(
            item,
            queueMembership: .customPlaylist(playlistID),
            collectionItems: playlistItems
        )
    }

    func synchronizeCustomPlaylistQueue(
        playlistID: CustomPlaylist.ID,
        playlistItems: [LibraryMediaItem]
    ) {
        guard playbackQueueMembership == .customPlaylist(playlistID),
              var activeQueue = queue else {
            return
        }
        let shouldAutoplay = playback.isPlaybackRequested

        let availableItemsByID = Self.mediaItemsByID(playlistItems)
        // Exact IDs cannot compete for an identity match. Reorders can refresh
        // their values directly without rebuilding an index or queue history.
        let hasExactRepresentations = queueItemsByID.allSatisfy { id, _ in
            guard let canonical = availableItemsByID[id] else { return false }
            return id.rootPath == canonical.id.rootPath
                && id.relativePath == canonical.id.relativePath
        }
        if hasExactRepresentations {
            queueItemsByID = availableItemsByID
        } else {
            reconcileActiveQueue(using: availableItemsByID)
        }
        guard let reconciledQueue = queue else {
            return
        }
        activeQueue = reconciledQueue

        let previousCurrentItemID = activeQueue.currentItem
        let structureChanged = activeQueue.synchronizeItems(
            playlistItems.map(\.id),
            pendingOrderPolicy: .authoritative
        )
        guard structureChanged else {
            if !hasExactRepresentations {
                let activeItemIDs = Set(activeQueue.items)
                queueItemsByID = queueItemsByID.filter {
                    activeItemIDs.contains($0.key)
                }
            }
            return
        }

        if activeQueue.isEmpty {
            stopPlaybackAndClearQueue()
            return
        }

        if !hasExactRepresentations {
            queueItemsByID.merge(availableItemsByID) { _, item in item }
            let activeItemIDs = Set(activeQueue.items)
            queueItemsByID = queueItemsByID.filter {
                activeItemIDs.contains($0.key)
            }
        }
        queue = activeQueue
        currentItemID = activeQueue.currentItem
        publishQueueChange(.structure)

        guard previousCurrentItemID != currentItemID else {
            return
        }
        invalidateLoad()
        playback.stop()
        loadedItemID = nil
        loadCurrentItem(
            attemptsRemaining: activeQueue.count,
            autoplay: shouldAutoplay
        )
    }

    func detachCustomPlaylistQueue(playlistID: CustomPlaylist.ID) {
        guard playbackQueueMembership == .customPlaylist(playlistID) else {
            return
        }
        playbackQueueMembership = .fixed
        publishQueueChange(.cursor)
    }

    func capturePlaybackContext() -> MediaLibraryPlaybackContext? {
        guard let queueSnapshot = makeQueueSnapshot() else {
            return nil
        }
        return MediaLibraryPlaybackContext(
            queueSnapshot: queueSnapshot,
            queueItemsByID: queueItemsByID,
            playbackCollection: activePlaybackCollection,
            currentTime: playback.currentTime,
            playbackIntent: playback.isPlaybackRequested
                ? .playing
                : .paused
        )
    }

    @discardableResult
    func openFilesTemporarily(_ urls: [URL]) async -> Bool {
        guard !isShutDown, !urls.isEmpty else {
            return false
        }
        playbackSelectionIntentRevision &+= 1
        temporaryPlaybackGeneration &+= 1
        let generation = temporaryPlaybackGeneration

        let resolution: TemporaryPlaybackResolution
        do {
            resolution = try await temporaryPlaybackSession.resolve(
                urls,
                librarySnapshot: itemsSnapshot.temporaryPlaybackSnapshot,
                librarySourceURLs: activeSources.map(\.url)
            )
        } catch is CancellationError {
            return false
        } catch {
            guard generation == temporaryPlaybackGeneration else {
                return false
            }
            externalPlaybackNotice = .noPlayableFiles
            return false
        }

        guard generation == temporaryPlaybackGeneration,
              !isShutDown else {
            return false
        }
        guard !resolution.items.isEmpty else {
            externalPlaybackNotice = .noPlayableFiles
            return false
        }

        externalPlaybackNotice = resolution.skippedItemCount > 0
            ? .skippedFiles(resolution.skippedItemCount)
            : nil

        invalidateLoad()
        let resolvedItemsByID = Self.mediaItemsByID(resolution.items)
        let itemIDs = resolution.items.map(\.id)
        isExternalPlaybackContext = true
        playbackQueueMembership = .external
        queueItemsByID = resolvedItemsByID
        queue = PlaybackQueue(
            items: itemIDs,
            startingAt: itemIDs.first,
            order: playbackOrder
        )
        currentItemID = queue?.currentItem
        temporaryItemIDs = resolution.temporaryItemIDs
        replaceUnavailableItemIDs(with: [])
        publishQueueChange()
        loadCurrentItem(attemptsRemaining: itemIDs.count)
        return true
    }

    func restorePlaybackContext(
        _ context: MediaLibraryPlaybackContext
    ) async -> MediaLibraryQueueRestoreResult {
        guard !isShutDown else {
            return .permanentlyUnavailable
        }
        guard var restoredQueue = PlaybackQueue(
                snapshot: context.queueSnapshot
              ),
              let restoredItemID = restoredQueue.currentItem else {
            finishPermanentlyUnavailableExternalRestore()
            return .permanentlyUnavailable
        }

        restoredQueue.setOrder(playbackOrder)

        temporaryPlaybackGeneration &+= 1
        let restoreGeneration = temporaryPlaybackGeneration
        invalidateLoad()
        temporaryPlaybackSession.end()
        temporaryItemIDs.removeAll()
        externalPlaybackNotice = nil
        playbackQueueMembership = Self.queueMembership(
            for: context.playbackCollection
        )
        queueItemsByID = context.queueItemsByID
        queue = restoredQueue
        currentItemID = restoredItemID
        replaceUnavailableItemIDs(
            with: unavailableItemIDs.intersection(
                context.queueItemsByID.keys
            )
        )
        publishQueueChange()

        let result = await loadRestoredQueueItem(
            attemptsRemaining: restoredQueue.count,
            attachToPlayerSurface: true,
            expectedTemporaryPlaybackGeneration: restoreGeneration
        )
        guard restoreGeneration == temporaryPlaybackGeneration,
              !isShutDown else {
            return .cancelled
        }
        if result == .permanentlyUnavailable {
            finishPermanentlyUnavailableExternalRestore()
            return result
        }
        guard result == .restored else {
            return result
        }
        playback.seek(to: context.currentTime)
        playback.setPlaybackIntent(context.playbackIntent)
        if isExternalPlaybackContext {
            isExternalPlaybackContext = false
            // Queue installation happened while persistence was frozen. Once
            // the original media is playable again, publish its restored
            // cursor as the durable session truth.
            publishQueueChange(.cursor)
        }
        return .restored
    }

    private func finishPermanentlyUnavailableExternalRestore() {
        guard isExternalPlaybackContext else {
            return
        }
        stopPlaybackAndClearQueue()
        temporaryPlaybackGeneration &+= 1
        temporaryPlaybackSession.end()
        temporaryItemIDs.removeAll()
        externalPlaybackNotice = nil
        isExternalPlaybackContext = false
        // The queue was cleared while persistence was frozen. Publish once
        // more after unfreezing so stale external URLs can never be saved.
        publishQueueChange(.cursor)
    }

    func removeRoot(_ root: MediaLibraryRoot) async {
        guard !isShutDown,
              roots.contains(where: { $0.id == root.id }),
              rootIDsPendingRemoval.insert(root.id).inserted else {
            return
        }
        // Source removals are durable user actions. A cancelled view task must
        // not abandon one after its persisted grant has been marked removed.
        // Serialize them so overlapping roots never publish competing plans.
        let predecessors = Array(rootRemovalTasks.values)
        let task = Task { [self] in
            for predecessor in predecessors { await predecessor.value }
            await performRootRemoval(root)
        }
        rootRemovalTasks[root.id] = task
        await task.value
        rootRemovalTasks[root.id] = nil
        rootIDsPendingRemoval.remove(root.id)
    }

    private func performRootRemoval(_ root: MediaLibraryRoot) async {
        guard !isShutDown else { return }
        invalidateSourceAccessOperation()
        invalidatePendingImport()
        let removedSource = MediaSource(url: root.url, kind: root.kind)
        mediaSession.prepareToRemoveSource(removedSource)
        let scanTasksToDrain = cancelAllScanTasks()
        let sortTasksToDrain = cancelAllSortTasks()
        guard let applied = await prepareAndApplyRootRemoval(root) else { return }
        let removedItemIDs = applied.removedItemIDs
        let removedThumbnailRootIDs = applied.thumbnailRootIDs
        let supersededRootPathsBeingRemoved = applied.supersededThumbnailRootPaths
        let playbackTouchesRemovedItems = applied.playbackTouched
        let shouldAutoplayAfterDrain = applied.shouldAutoplay
        let loadTasksToDrain = applied.loadTasks
        let removedCurrentItem = applied.removedCurrentItem
        let expectedReloadItemID = applied.reloadItemID
        let reloadGeneration = applied.reloadGeneration

        let thumbnailDrainTask = Task { @MainActor [mediaThumbnailProvider] in
            for rootID in removedThumbnailRootIDs.sorted(by: {
                $0.standardizedPath < $1.standardizedPath
            }) {
                await mediaThumbnailProvider.invalidateThumbnails(
                    forRootID: rootID
                )
            }
        }
        for task in scanTasksToDrain {
            await task.value
        }
        for task in sortTasksToDrain { await task.value }
        for task in loadTasksToDrain {
            await task.value
        }
        await playback.drainPendingWork()
        await mediaItemsWillBeRemovedHandler?(removedItemIDs)
        try? await playbackProgressStore?.removeProgress(
            for: removedItemIDs
        )
        await thumbnailDrainTask.value
        supersededThumbnailRootPaths.subtract(
            supersededRootPathsBeingRemoved
        )

        let remainingSessionSources = mediaSession.removeSource(removedSource)
        let remainingPendingRootPaths = Set(
            rootIDsPendingRemoval.map(\.standardizedPath)
        )
        let remainingSources = remainingSessionSources.filter {
            !remainingPendingRootPaths.contains(
                $0.id.standardizedPath
            )
        }

        guard !isShutDown else {
            return
        }

        installActiveSources(remainingSources)
        latestPreparedSources = remainingSources
        updateSourceAccessState(using: remainingSources)
        preparedSourcesNeedRefresh = !remainingSources.isEmpty
        let shouldReloadCurrentItem =
            (playbackTouchesRemovedItems || removedCurrentItem)
            && loadGeneration == reloadGeneration
            && currentItemID == expectedReloadItemID
            && expectedReloadItemID != nil
        if shouldReloadCurrentItem {
            loadCurrentItem(
                attemptsRemaining: queue?.count ?? 0,
                autoplay: shouldAutoplayAfterDrain
            )
        }

        if remainingSources.isEmpty {
            incompleteRootPaths = []
            scanState = .idle
            preparedSourcesNeedRefresh = false
            if queue == nil {
                stopPlaybackAndClearQueue()
            }
        } else {
            refresh(using: remainingSources)
        }
    }

    private func prepareAndApplyRootRemoval(
        _ root: MediaLibraryRoot
    ) async -> AppliedRootRemoval? {
        while !isShutDown {
            let stamp = PublicationStamp(
                itemsRevision: itemsRevision, queueStateRevision: queueStateRevision,
                queueMetadataRevision: queueMetadataRevision,
                unavailableRevision: unavailableItemsRevision,
                temporaryGeneration: temporaryPlaybackGeneration,
                loadedItemID: loadedItemID, membership: playbackQueueMembership
            )
            let sourceRevision = sourceAccessOperationGeneration
            let requestedSort = sort
            let pendingRoots = rootIDsPendingRemoval
            let pendingRootPaths = Set(pendingRoots.map(\.standardizedPath))
            let sessionSources = mediaSession.restoreSources()
            let remainingSources = sessionSources.filter {
                !pendingRootPaths.contains($0.id.standardizedPath)
            }
            var storage: RemovalStorage? = RemovalStorage(
                request: MediaLibraryRemovalRequest(
                    root: root, remainingSources: remainingSources,
                    sourceAccessURLs: sessionSources.map(\.url),
                    library: itemsSnapshot.library, queue: queue, currentItemID: currentItemID,
                    queueItemsByID: queueItemsByID, unavailableItemIDs: unavailableItemIDs,
                    supersededThumbnailRootPaths: supersededThumbnailRootPaths
                ),
                previousSnapshot: itemsSnapshot, previousItemsByID: visibleItemsByID,
                previousCanonicalIndex: canonicalItemLookupIndex
            )
            let pool = removalWorkPool
            let preparer = removalPreparer
            let task = Task<AppliedRootRemoval?, Error>.detached(priority: .userInitiated) {
                [weak self, storage = storage!] in
                try await pool.run {
                    defer { withExtendedLifetime(storage) {} }
                    let access = MediaLibraryRemovalScopeLease()
                    defer { withExtendedLifetime(access) {} }
                    try access.acquire(for: storage.request)
                    let plan = try await preparer.prepare(storage.request)
                    return await MainActor.run { () -> AppliedRootRemoval? in
                        guard let self, !self.isShutDown,
                              stamp.itemsRevision == self.itemsRevision,
                              stamp.queueStateRevision == self.queueStateRevision,
                              stamp.queueMetadataRevision == self.queueMetadataRevision,
                              stamp.unavailableRevision == self.unavailableItemsRevision,
                              stamp.temporaryGeneration == self.temporaryPlaybackGeneration,
                              stamp.loadedItemID == self.loadedItemID,
                              stamp.membership == self.playbackQueueMembership,
                              sourceRevision == self.sourceAccessOperationGeneration,
                              requestedSort == self.sort,
                              pendingRoots == self.rootIDsPendingRemoval else { return nil }
                        return self.applyRootRemoval(plan, root: root)
                    }
                }
            }
            storage = nil
            rootRemovalPreparationTasks[root.id] = task
            do {
                let applied = try await task.value
                rootRemovalPreparationTasks[root.id] = nil
                if let applied { return applied }
            } catch {
                rootRemovalPreparationTasks[root.id] = nil
                // The durable operation owns its worker and is not cancelled
                // by a view disappearing. A cooperative yield prevents a
                // transient worker rejection from busy-looping.
                await Task.yield()
            }
        }
        return nil
    }

    private func applyRootRemoval(
        _ plan: MediaLibraryRemovalPlan, root: MediaLibraryRoot
    ) -> AppliedRootRemoval {
        let removedIDs = plan.removedItemIDs
        let touchesPlayback = loadedItemID.map(removedIDs.contains) == true
            || loadTasks.values.contains { removedIDs.contains($0.itemID) }
            || (currentItemID.map(removedIDs.contains) == true && playback.readiness != .empty)
        let shouldAutoplay = playback.isPlaybackRequested || currentLoadTaskRecord?.autoplay == true
        let pendingLoads: [Task<Void, Never>]
        if touchesPlayback {
            pendingLoads = cancelAllLoadTasks()
            playback.stop()
            loadedItemID = nil
        } else { pendingLoads = [] }
        roots.removeAll { $0.id == root.id }
        replaceItems(with: plan.library, knownChanged: plan.libraryChanged)
        replaceUnavailableItemIDs(with: unavailableItemIDs.subtracting(removedIDs))
        queueItemsByID = plan.queueItemsByID
        if plan.queueChanged {
            if let nextQueue = plan.queue {
                queue = nextQueue
                publishQueueChange()
                if plan.removedCurrentItem { currentItemID = nextQueue.currentItem }
            } else { clearActiveQueue() }
        }
        installActiveSources(activeSources.filter {
            $0.id.standardizedPath != root.id.standardizedPath
        })
        return AppliedRootRemoval(
            removedItemIDs: removedIDs, thumbnailRootIDs: plan.thumbnailRootIDs,
            supersededThumbnailRootPaths: plan.supersededThumbnailRootPaths,
            removedCurrentItem: plan.removedCurrentItem,
            playbackTouched: touchesPlayback, shouldAutoplay: shouldAutoplay,
            loadTasks: pendingLoads, reloadItemID: currentItemID, reloadGeneration: loadGeneration
        )
    }

    func refresh() {
        guard canRefresh else {
            return
        }
        refresh(
            using: activeSources,
            candidateFileURLs: pendingExplicitFileURLs,
            autoplayFileURLs: pendingAutoplayFileURLs,
            explicitIntentGeneration: pendingAutoplayFileURLs.isEmpty
                ? nil
                : explicitPlayIntentGeneration,
            expandQueueForExplicitImport:
                pendingExplicitImportNeedsQueueExpansion,
            importGeneration: importGeneration
        )
    }

    /// Resumes the scan deliberately deferred when startup source restoration
    /// was cancelled to honor a newer window or file-open intent.
    @discardableResult
    func refreshDeferredSourcesIfNeeded() -> Bool {
        guard preparedSourcesNeedRefresh, canRefresh else {
            return false
        }
        refresh()
        return true
    }

    func play(_ item: LibraryMediaItem) {
        playbackSelectionIntentRevision &+= 1
        playInActiveCollection(item)
    }

    private func playInActiveCollection(_ item: LibraryMediaItem) {
        let membership = playbackQueueMembership
        let collectionItems: [LibraryMediaItem]
        switch membership {
        case .mediaLibrary:
            collectionItems = items
        case .customPlaylist, .fixed, .external:
            collectionItems = queue?.items.compactMap {
                queueItemsByID[$0]
            } ?? []
        }
        play(
            item,
            queueMembership: membership,
            collectionItems: collectionItems
        )
    }

    private func play(
        _ item: LibraryMediaItem,
        queueMembership: PlaybackQueueMembership,
        collectionItems: [LibraryMediaItem]
    ) {
        guard !isShutDown,
              !rootIDsPendingRemoval.contains(
                MediaLibraryRoot.ID(
                    standardizedPath: item.rootURL.standardizedFileURL.path
                )
              ),
              visibleItemsByID[item.id] != nil
                || queueItemsByID[item.id] != nil else {
            return
        }

        let selectionItemsRevision = itemsRevision
        if var activeQueue = queue {
            let currentItemBeforeSynchronization = activeQueue.currentItem
            let structureChanged: Bool
            if queueMembership == .mediaLibrary {
                let stamp = LibraryQueueSynchronizationStamp(
                    itemsRevision: itemsRevision,
                    structureRevision: queueStructureRevision,
                    metadataRevision: queueMetadataRevision
                )
                if playbackQueueMembership == .mediaLibrary,
                   libraryQueueSynchronizationStamp == stamp {
                    structureChanged = false
                } else {
                    queueItemsByID = visibleItemsByID
                    structureChanged = activeQueue.synchronizeItems(
                        itemsSnapshot.library.preparedQueueItems
                    )
                }
            } else if queueMembership == .external {
                queueItemsByID[item.id] = item
                structureChanged = activeQueue.synchronizeItems(
                    activeQueue.items + [item.id]
                )
            } else {
                queueItemsByID = Self.mediaItemsByID(collectionItems)
                structureChanged = activeQueue.synchronizeItems(collectionItems.map(\.id))
            }
            let shouldRecordCurrentInHistory =
                currentItemBeforeSynchronization.map {
                    $0 == activeQueue.currentItem
                } ?? false
            let historyBehavior: PlaybackQueueSelectionHistoryBehavior =
                shouldRecordCurrentInHistory
                ? .recordCurrent
                : .skipCurrent
            guard activeQueue.select(
                item.id,
                historyBehavior: historyBehavior
            ) != nil else {
                return
            }
            playbackQueueMembership = queueMembership
            let cursorChanged =
                currentItemBeforeSynchronization != activeQueue.currentItem

            var installedQueueState = queueStateRevision
            if structureChanged || cursorChanged {
                queue = activeQueue
                installedQueueState = queueStateRevision
                currentItemID = activeQueue.currentItem
                publishQueueChange(
                    structureChanged ? .structure : .cursor
                )
            }
            rememberLibraryQueueSynchronization(
                itemsRevision: selectionItemsRevision,
                installedQueueState: installedQueueState
            )
            markItemAvailable(item.id)
            if cursorChanged || loadedItemID != item.id {
                loadCurrentItem(attemptsRemaining: activeQueue.count)
            } else {
                playback.setPlaybackIntent(.playing)
            }
            return
        }

        let playbackItems = collectionItems
        guard !playbackItems.isEmpty else {
            return
        }
        playbackQueueMembership = queueMembership
        if queueMembership == .mediaLibrary {
            queueItemsByID = visibleItemsByID
            queue = PlaybackQueue(
                preparedItems: itemsSnapshot.library.preparedQueueItems,
                startingAt: item.id, order: playbackOrder
            )
        } else {
            queueItemsByID = Self.mediaItemsByID(playbackItems)
            queue = PlaybackQueue(
                items: playbackItems.map(\.id), startingAt: item.id, order: playbackOrder
            )
        }
        let installedQueueState = queueStateRevision
        currentItemID = queue?.currentItem
        publishQueueChange()
        rememberLibraryQueueSynchronization(
            itemsRevision: selectionItemsRevision,
            installedQueueState: installedQueueState
        )
        markItemAvailable(item.id)
        loadCurrentItem(attemptsRemaining: playbackItems.count)
    }

    private func rememberLibraryQueueSynchronization(
        itemsRevision: UInt64,
        installedQueueState: UInt64
    ) {
        guard playbackQueueMembership == .mediaLibrary,
              self.itemsRevision == itemsRevision,
              queueStateRevision == installedQueueState else {
            libraryQueueSynchronizationStamp = nil
            return
        }
        libraryQueueSynchronizationStamp = LibraryQueueSynchronizationStamp(
            itemsRevision: itemsRevision, structureRevision: queueStructureRevision,
            metadataRevision: queueMetadataRevision
        )
    }

    @discardableResult
    func playNext() -> Bool {
        let advanced = advanceToNextItem()
        if advanced { playbackSelectionIntentRevision &+= 1 }
        return advanced
    }

    private func advanceToNextItem() -> Bool {
        guard !isShutDown, let queueCount = queue?.count else {
            return false
        }

        if let nextID = queue?.nextItemWithoutAdvancing,
           !unavailableItemIDs.contains(nextID) {
            _ = queue?.moveToNext()
            currentItemID = nextID
            publishQueueChange(.cursor)
            loadCurrentItem(attemptsRemaining: queueCount)
            return true
        }

        guard var queue else {
            return false
        }
        guard let nextID = nextAvailableItem(
            in: &queue,
            maximumAdvances: queueCount
        ) else {
            return false
        }
        self.queue = queue
        currentItemID = nextID
        publishQueueChange(.cursor)
        loadCurrentItem(attemptsRemaining: queue.count)
        return true
    }

    func playPrevious() {
        guard !isShutDown,
              let queueCount = queue?.count,
              let previousID = queue?.previousItemWithoutAdvancing else {
            return
        }

        if previousID != queue?.currentItem,
           !unavailableItemIDs.contains(previousID) {
            _ = queue?.moveToPrevious()
            playbackSelectionIntentRevision &+= 1
            currentItemID = previousID
            publishQueueChange(.cursor)
            loadCurrentItem(attemptsRemaining: queueCount)
            return
        }

        guard var queue else {
            return
        }
        var priorID = queue.currentItem
        for _ in 0..<queueCount {
            guard let previousID = queue.moveToPrevious(),
                  previousID != priorID else {
                return
            }
            priorID = previousID
            guard !unavailableItemIDs.contains(previousID) else {
                continue
            }

            self.queue = queue
            playbackSelectionIntentRevision &+= 1
            currentItemID = previousID
            publishQueueChange(.cursor)
            loadCurrentItem(attemptsRemaining: queueCount)
            return
        }
    }

    func setPlaybackOrder(_ order: PlaybackOrder) {
        let mode: PlaybackMode = order == .ordered
            ? .ordered
            : .shuffled
        setPlaybackMode(mode)
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        switch mode {
        case .repeatCurrent:
            guard playbackRepeatBehavior != .currentItem else {
                return
            }
            playbackRepeatBehavior = .currentItem
            preferencesStore?.savePlaybackRepeatBehavior(.currentItem)

        case .ordered, .shuffled:
            if playbackRepeatBehavior != .queue {
                playbackRepeatBehavior = .queue
                preferencesStore?.savePlaybackRepeatBehavior(.queue)
            }

            let requestedOrder: PlaybackOrder = mode == .ordered
                ? .ordered
                : .shuffled
            updatePlaybackOrder(requestedOrder)
        }
    }

    private func updatePlaybackOrder(_ order: PlaybackOrder) {
        guard playbackOrder != order else {
            return
        }
        playbackOrder = order
        preferencesStore?.savePlaybackOrder(order)
        guard var queue else {
            return
        }
        queue.setOrder(order)
        self.queue = queue
        publishQueueChange()
    }

    func setSortField(_ field: MediaLibrarySortField) {
        guard !isShutDown, sort.field != field else {
            return
        }
        sort.field = field
        resortVisibleItems()
        preferencesStore?.saveLibrarySort(sort)
    }

    func toggleSortDirection() {
        guard !isShutDown else {
            return
        }
        sort.direction.toggle()
        resortVisibleItems()
        preferencesStore?.saveLibrarySort(sort)
    }

    func setSortDirection(_ direction: MediaLibrarySortDirection) {
        guard !isShutDown, sort.direction != direction else {
            return
        }
        sort.direction = direction
        resortVisibleItems()
        preferencesStore?.saveLibrarySort(sort)
    }

    private func resortVisibleItems() {
        guard !isShutDown else {
            return
        }
        sortGeneration &+= 1
        let generation = sortGeneration
        let previousTasks = Array(sortTasks.values)
        previousTasks.forEach { $0.cancel() }
        currentSortTaskID = nil

        guard items.count
                >= MediaLibraryPerformancePolicy
                    .backgroundSortMinimumItemCount else {
            replaceItems(with: sort.sorted(items), preservingContent: true)
            return
        }

        let baseItemsRevision = itemsRevision
        let baseLibrary = itemsSnapshot.library
        let requestedSort = sort
        let taskID = UUID()
        let task = Task { [weak self, snapshotPreparer] in
            defer {
                self?.finishSortTask(
                    taskID: taskID,
                    generation: generation
                )
            }
            do {
                for previousTask in previousTasks {
                    await previousTask.value
                }
                try Task.checkCancellation()
                guard let self,
                      !isShutDown,
                      generation == sortGeneration else {
                    return
                }
                let prepared = try await snapshotPreparer.sort(
                    baseLibrary,
                    using: requestedSort
                )
                try Task.checkCancellation()
                guard !isShutDown,
                      generation == sortGeneration,
                      baseItemsRevision == itemsRevision,
                      requestedSort == sort else {
                    return
                }
                replaceItems(with: prepared, preservingContent: true)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        sortTasks[taskID] = task
        currentSortTaskID = taskID
    }

    private func finishSortTask(taskID: UUID, generation: UInt64) {
        sortTasks[taskID] = nil
        if currentSortTaskID == taskID,
           generation == sortGeneration {
            currentSortTaskID = nil
        }
    }

    private func cancelAllSortTasks() -> [Task<Void, Never>] {
        sortGeneration &+= 1
        let tasks = Array(sortTasks.values)
        tasks.forEach { $0.cancel() }
        currentSortTaskID = nil
        return tasks
    }

    func makeQueueSnapshot() ->
        PlaybackQueueSnapshot<LibraryMediaItem.ID>? {
        if let cachedQueueSnapshot {
            return cachedQueueSnapshot
        }
        guard let snapshot = queue?.makeSnapshot() else {
            return nil
        }
        cachedQueueSnapshot = snapshot
        return snapshot
    }

    func restoreQueue(
        from snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        playbackCollection: PlaybackCollection = .mediaLibrary,
        queueMediaReferences: [MediaReference] = [],
        collectionItems: [LibraryMediaItem]? = nil,
        attachToPlayerSurface: Bool = false
    ) async -> MediaLibraryQueueRestoreResult {
        guard !Task.isCancelled, !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return .cancelled
        }
        guard scanState == .ready else { return .temporarilyUnavailable }
        queueRestorationGeneration &+= 1
        let restorationGeneration = queueRestorationGeneration
        queueRestorationTask?.cancel()
        let selectionRevision = playbackSelectionIntentRevision
        let capturedQueueState = queueStateRevision
        let capturedLoadGeneration = loadGeneration
        defer {
            if restorationGeneration == queueRestorationGeneration {
                queueRestorationTask = nil
            }
        }
        while true {
            guard !Task.isCancelled, !isShutDown, rootIDsPendingRemoval.isEmpty,
                  restorationGeneration == queueRestorationGeneration,
                  selectionRevision == playbackSelectionIntentRevision,
                  capturedQueueState == queueStateRevision,
                  capturedLoadGeneration == loadGeneration else { return .cancelled }
            guard scanState == .ready else { return .temporarilyUnavailable }
            let resolvedCollectionItems: [LibraryMediaItem]? = switch playbackCollection {
            case .mediaLibrary, .fixed: nil
            case let .customPlaylist(id): collectionItems ?? customPlaylistItemsProvider?(id)
            }
            let restoredCollection: PlaybackCollection
            if case .customPlaylist = playbackCollection, resolvedCollectionItems == nil {
                restoredCollection = .fixed
            } else { restoredCollection = playbackCollection }
            let contentRevision = itemsContentRevision
            let sourceRevision = sourceAccessOperationGeneration
            let requestedOrder = playbackOrder
            let request = MediaLibraryQueueRestoreRequest(
                snapshot: snapshot, references: queueMediaReferences,
                resolutionIndex: mediaReferenceResolutionIndex, itemsByID: visibleItemsByID,
                collectionItems: resolvedCollectionItems,
                requestedRootPaths: Set(activeSources.map(\.id.standardizedPath)),
                visibleRootPaths: Set(roots.map(\.id.standardizedPath)),
                incompleteRootPaths: incompleteRootPaths,
                hasUnavailableSources: mediaSession.hasUnavailablePersistedSources,
                playbackOrder: requestedOrder, usesCustomShuffler: reshuffleRestoredQueue != nil
            )
            let pool = queueRestorationPool
            let preparer = queueRestorationPreparer
            let task = Task {
                try await pool.run { try await preparer.prepare(request) }
            }
            queueRestorationTask = task
            let preparation: MediaLibraryQueueRestorePreparation
            do {
                preparation = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
            } catch { return .cancelled }
            guard !Task.isCancelled, !isShutDown, rootIDsPendingRemoval.isEmpty,
                  restorationGeneration == queueRestorationGeneration,
                  selectionRevision == playbackSelectionIntentRevision,
                  capturedQueueState == queueStateRevision,
                  capturedLoadGeneration == loadGeneration else { return .cancelled }
            // Library and playlist edits can interleave while the pure worker
            // runs. Retry only data changes; a newer playback intent wins.
            guard contentRevision == itemsContentRevision,
                  sourceRevision == sourceAccessOperationGeneration,
                  requestedOrder == playbackOrder else { continue }
            if case let .customPlaylist(id) = playbackCollection, collectionItems == nil,
               customPlaylistItemsProvider?(id) != resolvedCollectionItems { continue }
            let prepared: PreparedMediaLibraryQueueRestore
            switch preparation {
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .invalidSnapshot: return .permanentlyUnavailable
            case .emptyQueue:
                stopPlaybackAndClearQueue()
                return .permanentlyUnavailable
            case let .ready(value): prepared = value
            }
            var restoredQueue = prepared.queue
            if snapshot.order == requestedOrder, requestedOrder == .shuffled {
                reshuffleRestoredQueue?(&restoredQueue)
            }
            guard let restoredItemID = restoredQueue.currentItem else {
                return .permanentlyUnavailable
            }
            invalidateLoad()
            queueItemsByID = prepared.itemsByID
            playbackQueueMembership = Self.queueMembership(for: restoredCollection)
            queue = restoredQueue
            currentItemID = restoredItemID
            publishQueueChange()
            replaceUnavailableItemIDs(
                with: unavailableItemIDs.intersection(visibleItemsByID.keys)
            )
            return await loadRestoredQueueItem(
                attemptsRemaining: restoredQueue.count,
                attachToPlayerSurface: attachToPlayerSurface
            )
        }
    }

    func discardRestoredQueue() {
        stopPlaybackAndClearQueue()
    }

    func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        rootRemovalPreparationTasks.values.forEach { $0.cancel() }
        queueRestorationGeneration &+= 1
        queueRestorationTask?.cancel()
        queueRestorationTask = nil
        invalidateSourceAccessOperation()
        temporaryPlaybackGeneration &+= 1
        temporaryPlaybackSession.end()
        isExternalPlaybackContext = false
        playbackQueueMembership = .mediaLibrary
        temporaryItemIDs.removeAll()
        invalidatePendingImport()
        importNotice = nil
        playback.itemEndedHandler = nil
        playback.itemFailureHandler = nil

        let pendingScanTasks = cancelAllScanTasks()
        let pendingLoadTasks = cancelAllLoadTasks()
        let pendingSortTasks = cancelAllSortTasks()

        for task in pendingScanTasks {
            await task.value
        }
        for task in pendingLoadTasks {
            await task.value
        }
        await playback.drainPendingWork()
        for task in pendingSortTasks {
            await task.value
        }

        for task in Array(rootRemovalTasks.values) { await task.value }

        await prepareForMediaScopeShutdownHandler?()
        mediaSession.stop()
        installActiveSources([])
        latestPreparedSources = []
        unavailableSources = []
        sourceAccessState = .empty
        preparedSourcesNeedRefresh = false
        supersededThumbnailRootPaths = []
        incompleteRootPaths = []
        queue = nil
        currentItemID = nil
        loadedItemID = nil
        queueItemsByID.removeAll()
        visibleItemsByID.removeAll()
        canonicalItemLookupIndex = nil
        // Preserve the published final list while releasing the session-owned
        // lookup dictionaries once no further resolution can be requested.
        itemsSnapshot = ItemsSnapshot(
            revision: itemsRevision, contentRevision: itemsContentRevision,
            library: PreparedMediaLibraryItems(
                items: items, itemsByID: [:],
                resolutionIndex: MediaReferenceResolutionIndex(items: []),
                rootURLsByPath: [:], temporaryPlaybackSnapshot: .empty,
                preparedQueueItems: PreparedPlaybackQueueItems(items: [])
            )
        )
        libraryQueueSynchronizationStamp = nil
        lastPublishedScanSourcePaths = []
        lastPublishedScanSort = nil
        lastPublishedScanMembership = nil
    }

    private func refresh(
        using sources: [MediaSource],
        candidateFileURLs: [URL] = [],
        autoplayFileURLs: [URL] = [],
        explicitIntentGeneration: UInt64? = nil,
        expandQueueForExplicitImport: Bool = false,
        importGeneration: UInt64? = nil
    ) {
        scanGeneration &+= 1
        let generation = scanGeneration
        cancelCurrentScanTask()
        installActiveSources(sources)
        updateSourceAccessState(using: sources)
        scanState = .scanning

        let taskID = UUID()
        currentScanSourcePaths = sourcePathSet(sources)
        let candidateSources = candidateFileURLs.map {
            MediaSource(url: $0, kind: .file)
        }
        let scanWorkPool = scanWorkPool
        let task = Task { [weak self, scanner] in
            defer {
                self?.finishScanTask(taskID)
            }
            do {
                var snapshotForAllSources: MediaLibrarySnapshot?
                var didFulfillExplicitIntent = false
                if !candidateSources.isEmpty {
                    do {
                        let candidateSnapshot = try await Self.boundedScan(
                            sources: candidateSources,
                            scanner: scanner,
                            pool: scanWorkPool
                        )
                        try Task.checkCancellation()
                        guard let self,
                              generation == scanGeneration,
                              !isShutDown else {
                            return
                        }
                        let representedCandidates =
                            representImportedCandidates(
                                candidateSnapshot.items,
                                using: sources
                            )
                        try await mergeImportedCandidates(
                            representedCandidates,
                            scanGeneration: generation
                        )
                        if isExplicitIntentCurrent(explicitIntentGeneration) {
                            let selectionRevision = playbackSelectionIntentRevision
                            let candidate = try await firstItemAsync(
                                matching: autoplayFileURLs, in: representedCandidates
                            )
                            try Task.checkCancellation()
                            guard generation == scanGeneration, !isShutDown else { return }
                            if selectionRevision != playbackSelectionIntentRevision {
                                clearPendingExplicitImport(matching: explicitIntentGeneration)
                                didFulfillExplicitIntent = true
                            } else if isExplicitIntentCurrent(explicitIntentGeneration), let candidate {
                                activateImportedItem(candidate, expandQueue: expandQueueForExplicitImport)
                                clearPendingExplicitImport(matching: explicitIntentGeneration)
                                didFulfillExplicitIntent = true
                            }
                        }
                        if sourcePathSet(sources)
                            == sourcePathSet(candidateSources) {
                            snapshotForAllSources = candidateSnapshot
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A rejected explicit file must not prevent valid
                        // folders or later files in the import from scanning.
                    }
                }

                let snapshot = if let snapshotForAllSources {
                    snapshotForAllSources
                } else {
                    try await Self.boundedScan(
                        sources: sources, scanner: scanner, pool: scanWorkPool
                    )
                }
                try Task.checkCancellation()
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                try await publish(
                    snapshot,
                    for: sources,
                    scanGeneration: generation
                )
                if !didFulfillExplicitIntent,
                   isExplicitIntentCurrent(explicitIntentGeneration) {
                    let selectionRevision = playbackSelectionIntentRevision
                    let candidate = try await firstItemAsync(matching: autoplayFileURLs)
                    try Task.checkCancellation()
                    guard generation == scanGeneration, !isShutDown else { return }
                    if selectionRevision == playbackSelectionIntentRevision,
                       isExplicitIntentCurrent(explicitIntentGeneration), let candidate {
                        activateImportedItem(candidate, expandQueue: expandQueueForExplicitImport)
                    }
                    clearPendingExplicitImport(matching: explicitIntentGeneration)
                }
                if let importGeneration,
                   importGeneration == self.importGeneration,
                   sourcePathSet(sources)
                    == sourcePathSet(latestPreparedSources) {
                    preparedSourcesNeedRefresh = false
                }
            } catch is CancellationError {
                return
            } catch let error as MediaLibraryScanError {
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                scanState = .failed(error.userFacingFailure)
            } catch {
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                scanState = .failed(.other)
            }
        }
        scanTasks[taskID] = task
        currentScanTaskID = taskID
    }

    private func publish(
        _ snapshot: MediaLibrarySnapshot,
        for requestedSources: [MediaSource],
        scanGeneration generation: UInt64
    ) async throws {
        let requestedSourcePaths = sourcePathSet(requestedSources)
        var pendingPrepared: PreparedMediaLibrarySnapshot?
        var pendingSort: MediaLibrarySort?
        if lastPublishedScanSourcePaths == requestedSourcePaths,
           lastPublishedScanSort == sort,
           lastPublishedScanItemsRevision == itemsRevision,
           itemsSnapshot.library.orderingContext?.matches(
               sort: sort, locale: Locale.current
           ) == true {
            let capturedItemsRevision = itemsRevision
            let capturedStructureRevision = queueStructureRevision
            let capturedSort = sort
            let capturedMembership = playbackQueueMembership
            let capturedRoots = roots
            let capturedIncompleteRoots = incompleteRootPaths
            let unchanged = try await Self.snapshotMatchesVisibleLibrary(
                snapshot,
                requestedSourcePaths: requestedSourcePaths,
                roots: roots,
                itemsByID: visibleItemsByID,
                incompleteRootPaths: incompleteRootPaths
            )
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }
            if unchanged, capturedItemsRevision == itemsRevision,
               capturedSort == sort,
               itemsSnapshot.library.orderingContext?.matches(
                   sort: capturedSort, locale: Locale.current
               ) == true,
               capturedRoots == roots,
               capturedIncompleteRoots == incompleteRootPaths {
                if capturedStructureRevision == queueStructureRevision,
                   capturedMembership == playbackQueueMembership,
                   lastPublishedScanMembership == capturedMembership,
                   lastPublishedScanQueueStructureRevision == capturedStructureRevision {
                    if requestedSourcePaths == sourcePathSet(latestPreparedSources) {
                        preparedSourcesNeedRefresh = false
                    }
                    scanState = .ready
                    return
                }
                // A new queue still needs reconciliation, but cannot change
                // the already verified library order, indexes or values.
                pendingPrepared = PreparedMediaLibrarySnapshot(
                    roots: roots, library: itemsSnapshot.library,
                    incompleteRootPaths: incompleteRootPaths
                )
                pendingSort = capturedSort
            }
        }
        while true {
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }

            let requestedSort = sort
            var prepared: PreparedMediaLibrarySnapshot?
            if pendingSort == requestedSort, pendingPrepared != nil {
                prepared = pendingPrepared
            } else {
                prepared = try await snapshotPreparer.prepare(
                    snapshot,
                    requestedSourcePaths: requestedSourcePaths,
                    sort: requestedSort,
                    previousLibrary: itemsSnapshot.library,
                    previousSort: itemsSnapshot.library.orderingContext?.sort
                )
            }
            pendingPrepared = nil
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }
            guard sort == requestedSort else {
                continue
            }

            let stamp = PublicationStamp(
                itemsRevision: itemsRevision,
                queueStateRevision: queueStateRevision,
                queueMetadataRevision: queueMetadataRevision,
                unavailableRevision: unavailableItemsRevision,
                temporaryGeneration: temporaryPlaybackGeneration,
                loadedItemID: loadedItemID,
                membership: playbackQueueMembership
            )
            var storage: PublicationStorage? = PublicationStorage(
                request: MediaLibraryPublicationRequest(
                    prepared: prepared!, oldItems: items, queue: queue,
                    cachedQueueSnapshot: cachedQueueSnapshot,
                    queueItemsByID: queueItemsByID,
                    unavailableItemIDs: unavailableItemIDs,
                    temporaryItemIDs: temporaryItemIDs,
                    currentItemID: currentItemID, loadedItemID: loadedItemID,
                    synchronizeLibraryQueue: playbackQueueMembership == .mediaLibrary
                ),
                previousSnapshot: itemsSnapshot,
                previousItemsByID: visibleItemsByID,
                previousCanonicalIndex: canonicalItemLookupIndex
            )
            let pool = publicationWorkPool
            let preparer = snapshotPreparer
            let task = Task<PublicationResult, Error>.detached(priority: .userInitiated) {
                [weak self, storage = storage!] in
                try await pool.run {
                    defer { withExtendedLifetime(storage) {} }
                    let plan = try await storage.request.prepare(using: preparer)
                    try Task.checkCancellation()
                    return try await MainActor.run {
                        try Task.checkCancellation()
                        guard let self, generation == self.scanGeneration,
                              !self.isShutDown else { throw CancellationError() }
                        guard self.sort == requestedSort,
                              stamp.itemsRevision == self.itemsRevision,
                              stamp.queueStateRevision == self.queueStateRevision,
                              stamp.queueMetadataRevision == self.queueMetadataRevision,
                              stamp.unavailableRevision == self.unavailableItemsRevision,
                              stamp.temporaryGeneration == self.temporaryPlaybackGeneration,
                              stamp.loadedItemID == self.loadedItemID,
                              stamp.membership == self.playbackQueueMembership else {
                            return .retry(storage.request.prepared)
                        }
                        self.applyPublication(
                            plan, prepared: storage.request.prepared,
                            requestedSourcePaths: requestedSourcePaths,
                            requestedSort: requestedSort
                        )
                        return .applied(PublicationPruning(
                            itemIDs: plan.keepingItemIDs, rootPaths: plan.completeRootPaths
                        ))
                    }
                }
            }
            storage = nil
            prepared = nil
            let applied = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            switch applied {
            case let .retry(prepared):
                pendingPrepared = prepared
                pendingSort = requestedSort
            case let .applied(pruning):
                try? await playbackProgressStore?.pruneProgress(
                    keeping: pruning.itemIDs, withinRootPaths: pruning.rootPaths
                )
                return
            }
        }
    }

    private func applyPublication(
        _ plan: MediaLibraryPublicationPlan,
        prepared: PreparedMediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        requestedSort: MediaLibrarySort
    ) {
        let wasTemporaryPlayback = !temporaryItemIDs.isEmpty
        let previousCurrentItemID = currentItemID
        let shouldAutoplay = playback.isPlaybackRequested
            || currentLoadTaskRecord?.autoplay == true
        mediaThumbnailProvider.allowThumbnails(forRootIDs: Set(prepared.roots.map(\.id)))
        if roots != prepared.roots { roots = prepared.roots }
        replaceItems(with: prepared.library, knownChanged: plan.libraryChanged)
        incompleteRootPaths = prepared.incompleteRootPaths
        queueItemsByID = plan.queueItemsByID
        if plan.queueChanged {
            queue = plan.queue
            currentItemID = plan.currentItemID
            loadedItemID = plan.loadedItemID
        }
        temporaryItemIDs = plan.temporaryItemIDs
        if wasTemporaryPlayback, temporaryItemIDs.isEmpty { temporaryPlaybackSession.end() }
        if plan.queueChanged { publishQueueChange() }
        if plan.unavailableChanged {
            unavailableItemIDs = plan.unavailableItemIDs
            unavailableItemsRevision &+= 1
        }
        if previousCurrentItemID != currentItemID {
            invalidateLoad()
            playback.stop()
            loadedItemID = nil
            if let queue {
                loadCurrentItem(attemptsRemaining: queue.count, autoplay: shouldAutoplay)
            }
        }
        if requestedSourcePaths == sourcePathSet(latestPreparedSources) {
            preparedSourcesNeedRefresh = false
        }
        scanState = .ready
        lastPublishedScanSourcePaths = requestedSourcePaths
        lastPublishedScanSort = requestedSort
        lastPublishedScanMembership = playbackQueueMembership
        lastPublishedScanItemsRevision = itemsRevision
        lastPublishedScanQueueStructureRevision = queueStructureRevision
    }

    private nonisolated static func boundedScan(
        sources: [MediaSource],
        scanner: any MediaLibraryScanning,
        pool: BoundedMediaWorkPool
    ) async throws -> MediaLibrarySnapshot {
        try await pool.run {
            return try await scanner.scan(sources: sources)
        }
    }

    private nonisolated static func snapshotMatchesVisibleLibrary(
        _ snapshot: MediaLibrarySnapshot,
        requestedSourcePaths: Set<String>,
        roots: [MediaLibraryRoot],
        itemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        incompleteRootPaths: Set<String>
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard snapshot.roots.filter({
            requestedSourcePaths.contains($0.id.standardizedPath)
        }) == roots,
        snapshot.incompleteRootPaths.intersection(requestedSourcePaths)
            == incompleteRootPaths else { return false }
        var acceptedCount = 0
        for item in snapshot.items where requestedSourcePaths.contains(item.id.rootPath) {
            if acceptedCount.isMultiple(of: 256) { try Task.checkCancellation() }
            guard itemsByID[item.id] == item else { return false }
            acceptedCount += 1
        }
        return acceptedCount == itemsByID.count
    }

    private func mergeImportedCandidates(
        _ candidates: [LibraryMediaItem],
        scanGeneration generation: UInt64
    ) async throws {
        let candidateIDs = Set(candidates.map(\.id))
        while true {
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }
            let baseItemsRevision = itemsRevision
            let baseItems = items
            let requestedSort = sort
            let prepared = try await snapshotPreparer.merge(
                candidates,
                into: baseItems,
                sort: requestedSort
            )
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }
            guard baseItemsRevision == itemsRevision,
                  requestedSort == sort else {
                continue
            }
            replaceItems(with: prepared)
            replaceUnavailableItemIDs(
                with: unavailableItemIDs.subtracting(candidateIDs)
            )
            return
        }
    }

    @discardableResult
    private func replaceItems(
        with items: [LibraryMediaItem], preservingContent: Bool = false
    ) -> Bool {
        guard self.items != items else {
            return false
        }
        var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        itemsByID.reserveCapacity(items.count)
        for item in items {
            itemsByID[item.id] = item
        }
        return replaceItems(
            with: PreparedMediaLibraryItems(
                items: items,
                itemsByID: itemsByID,
                resolutionIndex: preservingContent ? itemsSnapshot.resolutionIndex : nil,
                temporaryPlaybackSnapshot: preservingContent
                    ? itemsSnapshot.temporaryPlaybackSnapshot.reordered(items: items)
                    : nil,
                orderingContext: preservingContent
                    ? PreparedMediaLibraryOrdering(sort: sort, locale: Locale.current)
                    : nil
            ),
            preservingContent: preservingContent
        )
    }

    @discardableResult
    private func replaceItems(
        with prepared: PreparedMediaLibraryItems,
        preservingContent: Bool = false,
        knownChanged: Bool? = nil
    ) -> Bool {
        guard knownChanged ?? (items != prepared.items) else {
            return false
        }
        if !preservingContent {
            visibleItemsByID = prepared.itemsByID
            canonicalItemLookupIndex = nil
        }
        let library: PreparedMediaLibraryItems
        if preservingContent {
            library = PreparedMediaLibraryItems(
                items: prepared.items, itemsByID: visibleItemsByID,
                resolutionIndex: itemsSnapshot.resolutionIndex,
                rootURLsByPath: itemsSnapshot.rootURLsByPath,
                temporaryPlaybackSnapshot: itemsSnapshot.temporaryPlaybackSnapshot
                    .reordered(items: prepared.items),
                orderingContext: prepared.orderingContext,
                preparedQueueItems: prepared.preparedQueueItems
            )
        } else {
            library = prepared
        }
        itemsSnapshot = ItemsSnapshot(
            revision: itemsSnapshot.revision &+ 1,
            contentRevision: itemsSnapshot.contentRevision &+ (preservingContent ? 0 : 1),
            library: library
        )
        return true
    }

    private func replaceUnavailableItemIDs(
        with itemIDs: Set<LibraryMediaItem.ID>
    ) {
        guard unavailableItemIDs != itemIDs else {
            return
        }
        unavailableItemIDs = itemIDs
        unavailableItemsRevision &+= 1
    }

    private func markItemAvailable(_ itemID: LibraryMediaItem.ID) {
        guard unavailableItemIDs.remove(itemID) != nil else {
            return
        }
        unavailableItemsRevision &+= 1
    }

    private func markItemUnavailable(_ itemID: LibraryMediaItem.ID) {
        guard unavailableItemIDs.insert(itemID).inserted else {
            return
        }
        unavailableItemsRevision &+= 1
    }

    private func representImportedCandidates(
        _ candidates: [LibraryMediaItem],
        using sources: [MediaSource]
    ) -> [LibraryMediaItem] {
        let sourceDescriptors = sourcePathDescriptors(for: sources)
        return candidates.map { candidate in
            let candidatePath = mediaPathDescriptor(for: candidate.url)
            guard let coverageMatch = sourceDescriptors.lazy.compactMap({
                $0.coverageMatch(for: candidatePath)
            }).first else {
                return candidate
            }

            let matchedSource = coverageMatch.source
            if matchedSource.kind == .file {
                let rootID = MediaLibraryRoot.ID(
                    standardizedPath: matchedSource.id.standardizedPath
                )
                let rootName = roots.first(where: { $0.id == rootID })?
                    .displayName ?? matchedSource.url.lastPathComponent
                return LibraryMediaItem(
                    rootURL: matchedSource.url,
                    rootName: rootName,
                    kind: .file,
                    url: matchedSource.url,
                    displayName: candidate.displayName,
                    relativePath: "",
                    relativeDirectory: "",
                    creationDate: candidate.creationDate,
                    modificationDate: candidate.modificationDate,
                    fileSize: candidate.fileSize,
                    fileIdentity: candidate.fileIdentity
                )
            }

            let rootComponents = coverageMatch.sourcePathComponents
            let mediaComponents = coverageMatch.mediaPathComponents
            guard mediaComponents.starts(with: rootComponents) else {
                return candidate
            }
            let relativeComponents = mediaComponents.dropFirst(
                rootComponents.count
            )
            guard !relativeComponents.isEmpty else {
                return candidate
            }
            let relativePath = relativeComponents.joined(separator: "/")
            let relativeDirectory = relativeComponents
                .dropLast()
                .joined(separator: "/")
            let rootID = MediaLibraryRoot.ID(
                standardizedPath: matchedSource.id.standardizedPath
            )
            let rootName = roots.first(where: { $0.id == rootID })?
                .displayName ?? matchedSource.url.lastPathComponent

            // A covered explicit file is read through the active folder
            // grant. Publish that ownership before SwiftUI can request a
            // thumbnail so no temporary file-root Quick Look task can
            // outlive the folder's security scope.
            return LibraryMediaItem(
                rootURL: matchedSource.url,
                rootName: rootName,
                kind: .folder,
                url: matchedSource.url.appendingPathComponent(relativePath),
                displayName: candidate.displayName,
                relativePath: relativePath,
                relativeDirectory: relativeDirectory,
                creationDate: candidate.creationDate,
                modificationDate: candidate.modificationDate,
                fileSize: candidate.fileSize,
                fileIdentity: candidate.fileIdentity
            )
        }
    }

    private func firstItemAsync(
        matching urls: [URL], in candidates: [LibraryMediaItem]? = nil
    ) async throws -> LibraryMediaItem? {
        try await itemsAsync(matching: urls, in: candidates).compactMap { $0 }.first
    }

    private func itemsAsync(
        matching urls: [URL], in candidates: [LibraryMediaItem]? = nil,
        sourceURLs: [URL]? = nil
    ) async throws -> [LibraryMediaItem?] {
        while true {
            try Task.checkCancellation()
            guard !isShutDown else { throw CancellationError() }
            let revision = itemsContentRevision
            let orderRevision = itemsRevision
            let lookupItems = candidates ?? items
            let itemsByID = candidates.map(Self.mediaItemsByID) ?? visibleItemsByID
            let exact = urls.map { itemsByID[LibraryMediaItem.ID(mediaURL: $0)] }
            if !exact.contains(where: { $0 == nil }) { return exact }
            let roots = candidates.map { values in
                Dictionary(values.map { ($0.id.rootPath, $0.rootURL) },
                           uniquingKeysWith: { first, _ in first })
            } ?? itemsSnapshot.rootURLsByPath
            // Equal URL strings can carry different bookmark scope contexts.
            // Both bounded source snapshots retain their exact claims.
            let sourceClaims = activeSources.map(\.url) + (sourceURLs ?? [])
            let request = MediaLibraryCanonicalLookupRequest(
                urls: urls, items: lookupItems, itemsByID: itemsByID,
                rootURLsByPath: roots, contentRevision: revision,
                cachedIndex: candidates == nil ? canonicalItemLookupIndex : nil,
                sourceURLs: sourceClaims
            )
            let lookup = canonicalLookup
            let prepared = try await canonicalLookupPool.run { try lookup.prepare(request) }
            try Task.checkCancellation()
            guard !isShutDown else { throw CancellationError() }
            if candidates == nil {
                guard revision == itemsContentRevision, orderRevision == itemsRevision else { continue }
                canonicalItemLookupIndex = prepared.index
#if DEBUG
                if prepared.rebuiltIndex { canonicalItemLookupIndexBuildCountForTesting += 1 }
#endif
            }
            return prepared.matches
        }
    }

    private func firstItem(
        matching fileURLs: [URL],
        in candidates: [LibraryMediaItem]? = nil
    ) -> LibraryMediaItem? {
        items(matching: fileURLs, in: candidates).compactMap { $0 }.first
    }

    private func items(
        matching fileURLs: [URL],
        in candidates: [LibraryMediaItem]? = nil
    ) -> [LibraryMediaItem?] {
        let candidateItems = candidates ?? self.items
        let candidatesByID = candidates == nil
            ? visibleItemsByID
            : Self.mediaItemsByID(candidateItems)
        var matches = fileURLs.map {
            candidatesByID[LibraryMediaItem.ID(mediaURL: $0)]
        }
        guard matches.contains(where: { $0 == nil }) else {
            return matches
        }

        let canonicalIndex = if candidates == nil {
            canonicalItemLookupIndexForVisibleItems()
        } else {
            makeMediaLibraryCanonicalLookupIndex(
                rootURLsByPath: Dictionary(
                    candidateItems.map { ($0.id.rootPath, $0.rootURL) },
                    uniquingKeysWith: { first, _ in first }
                ),
                contentRevision: itemsContentRevision
            )
        }
        for index in fileURLs.indices where matches[index] == nil {
            let components = canonicalComparisonURL(fileURLs[index]).pathComponents
            var matchedIDs: Set<LibraryMediaItem.ID> = []
            for root in canonicalIndex.rootResolutions {
                guard components.starts(with: root.canonicalComponents) else { continue }
                let relativePath = components.dropFirst(root.canonicalComponents.count)
                    .joined(separator: "/")
                let id = LibraryMediaItem.ID(
                    rootPath: root.rootURL.standardizedFileURL.path,
                    relativePath: relativePath
                )
                if candidatesByID[id] != nil { matchedIDs.insert(id) }
            }
            if matchedIDs.count == 1, let id = matchedIDs.first {
                matches[index] = candidatesByID[id]
            } else if !matchedIDs.isEmpty {
                // Preserve the previous index's last-item-wins rule for rare
                // overlapping alias roots without indexing every media path.
                matches[index] = candidateItems.last { matchedIDs.contains($0.id) }
            }
        }
        return matches
    }

    private func canonicalItemLookupIndexForVisibleItems()
        -> MediaLibraryCanonicalLookupIndex {
        // A root symlink can be retargeted without publishing new items.
        // Revalidate only the roots before reusing the large item index.
        if let canonicalItemLookupIndex,
           canonicalItemLookupIndex.contentRevision == itemsContentRevision,
           canonicalItemLookupIndex.rootResolutions.allSatisfy({ resolution in
               canonicalComparisonURL(resolution.rootURL).path
                   == resolution.canonicalPath
           }) {
            return canonicalItemLookupIndex
        }

        let index = makeMediaLibraryCanonicalLookupIndex(
            rootURLsByPath: itemsSnapshot.rootURLsByPath,
            contentRevision: itemsContentRevision
        )
        canonicalItemLookupIndex = index
#if DEBUG
        canonicalItemLookupIndexBuildCountForTesting += 1
#endif
        return index
    }

    private func makeMediaLibraryCanonicalLookupIndex(
        rootURLsByPath: [String: URL],
        contentRevision: UInt64
    ) -> MediaLibraryCanonicalLookupIndex {
        let rootResolutions = rootURLsByPath.values.map { rootURL in
            let canonicalURL = canonicalComparisonURL(rootURL)
            return MediaLibraryCanonicalLookupIndex.RootResolution(
                rootURL: rootURL, canonicalPath: canonicalURL.path,
                canonicalComponents: canonicalURL.pathComponents
            )
        }
        return MediaLibraryCanonicalLookupIndex(
            contentRevision: contentRevision,
            rootResolutions: rootResolutions
        )
    }

    private func activateImportedItem(
        _ item: LibraryMediaItem,
        expandQueue: Bool
    ) {
        let alreadyLoadingOrLoaded = currentItemID == item.id
            && (
                loadedItemID == item.id
                    || currentLoadTaskRecord?.itemID == item.id
            )
        guard alreadyLoadingOrLoaded else {
            playInActiveCollection(item)
            return
        }

        reconcileQueuedItemValuesFromVisibleItems()
        guard expandQueue, var activeQueue = queue else {
            return
        }
        queueItemsByID.merge(visibleItemsByID) { _, visibleItem in
            visibleItem
        }
        let synchronizedIDs = playbackQueueMembership == .external
            ? activeQueue.items
            : items.map(\.id)
        guard activeQueue.synchronizeItems(synchronizedIDs) else {
            return
        }
        queue = activeQueue
        currentItemID = activeQueue.currentItem
        replaceUnavailableItemIDs(
            with: Set(unavailableItemIDs.filter {
                visibleItemsByID[$0] != nil
            })
        )
        publishQueueChange()
    }

    private func appendPendingExplicitFiles(_ urls: [URL]) {
        var knownIDs = Set(
            pendingExplicitFileURLs.map(LibraryMediaItem.ID.init(mediaURL:))
        )
        for url in urls {
            let id = LibraryMediaItem.ID(mediaURL: url)
            if knownIDs.insert(id).inserted {
                pendingExplicitFileURLs.append(url.standardizedFileURL)
            }
        }
    }

    private func isExplicitIntentCurrent(_ generation: UInt64?) -> Bool {
        guard let generation, !pendingAutoplayFileURLs.isEmpty else {
            return false
        }
        return generation == explicitPlayIntentGeneration
    }

    private func clearPendingExplicitImport(matching generation: UInt64?) {
        guard let generation,
              generation == explicitPlayIntentGeneration else {
            return
        }
        pendingExplicitFileURLs.removeAll()
        pendingAutoplayFileURLs.removeAll()
        pendingExplicitImportNeedsQueueExpansion = false
        explicitPlayIntentGeneration &+= 1
    }

    private func invalidatePendingImport() {
        importGeneration &+= 1
        lastCommittedImportGeneration = importGeneration
        pendingExplicitFileURLs.removeAll()
        pendingAutoplayFileURLs.removeAll()
        pendingExplicitImportNeedsQueueExpansion = false
        explicitPlayIntentGeneration &+= 1
    }

    private func isCurrentScanTargeting(_ sources: [MediaSource]) -> Bool {
        currentScanTaskID != nil
            && currentScanSourcePaths == sourcePathSet(sources)
    }

    private func reconcileQueuedItemValuesFromVisibleItems() {
        reconcileActiveQueue(using: visibleItemsByID)
    }

    private func reconcileActiveQueue(
        using availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    ) {
        let resolutionIndex = MediaReferenceResolutionIndex(
            items: Array(availableItemsByID.values)
        )
        let resolution = resolutionIndex.resolveQueuedItems(queueItemsByID)
        let resolvedItemsByQueuedID = resolution.resolvedItemsByQueuedID
        queueItemsByID = resolution.canonicalItemsByID

        guard queue != nil else {
            return
        }
        guard let snapshot = makeQueueSnapshot() else {
            return
        }
        let remappedSnapshot = remappedQueueSnapshot(
            snapshot,
            using: resolvedItemsByQueuedID
        )
        guard remappedSnapshot != snapshot else {
            return
        }
        guard let remappedQueue: PlaybackQueue<LibraryMediaItem.ID> = PlaybackQueue(
            snapshot: remappedSnapshot
        ) else {
            return
        }
        self.queue = remappedQueue
        currentItemID = remappedQueue.currentItem
        loadedItemID = loadedItemID.map {
            resolvedItemsByQueuedID[$0]?.id ?? $0
        }
        replaceUnavailableItemIDs(
            with: Set(unavailableItemIDs.map {
                resolvedItemsByQueuedID[$0]?.id ?? $0
            })
        )
        publishQueueChange()
    }

    private func remappedQueueSnapshot(
        _ snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        using resolvedItemsByQueuedID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ]
    ) -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        func canonicalID(
            _ id: LibraryMediaItem.ID
        ) -> LibraryMediaItem.ID {
            resolvedItemsByQueuedID[id]?.id ?? id
        }
        func remap(
            _ location: PlaybackQueueSnapshotLocation<LibraryMediaItem.ID>
        ) -> PlaybackQueueSnapshotLocation<LibraryMediaItem.ID> {
            PlaybackQueueSnapshotLocation(
                item: canonicalID(location.item),
                roundNumber: location.roundNumber,
                position: location.position
            )
        }

        return PlaybackQueueSnapshot(
            items: snapshot.items.map(canonicalID),
            order: snapshot.order,
            currentItem: canonicalID(snapshot.currentItem),
            roundNumber: snapshot.roundNumber,
            currentRoundPosition: snapshot.currentRoundPosition,
            remainingItems: snapshot.remainingItems.map(canonicalID),
            remainingIndex: snapshot.remainingIndex,
            history: snapshot.history.map(remap),
            forwardHistory: snapshot.forwardHistory.map(remap)
        )
    }

    private func sourcePathSet(
        _ sources: [MediaSource]
    ) -> Set<String> {
        Set(sources.map { $0.id.standardizedPath })
    }

    @discardableResult
    private func beginSourceAccessOperation() -> UInt64 {
        sourceAccessOperationGeneration &+= 1
        return sourceAccessOperationGeneration
    }

    private func invalidateSourceAccessOperation() {
        sourceAccessOperationGeneration &+= 1
    }

    private func isCurrentSourceAccessOperation(
        _ generation: UInt64
    ) -> Bool {
        !isShutDown && generation == sourceAccessOperationGeneration
    }

    private func updateSourceAccessState(using sources: [MediaSource]) {
        unavailableSources = mediaSession.unavailablePersistedSources
        if !unavailableSources.isEmpty {
            sourceAccessState = sources.isEmpty
                ? .temporarilyUnavailable
                : .partiallyUnavailable
        } else {
            sourceAccessState = sources.isEmpty ? .empty : .available
        }
    }

    private func recordSupersededThumbnailRoots(
        previousSources: [MediaSource],
        activeSources: [MediaSource]
    ) {
        let activeSourceIDs = Set(activeSources.map(\.id))
        let supersededFileSources = previousSources.filter {
            $0.kind == .file && !activeSourceIDs.contains($0.id)
        }
        guard !supersededFileSources.isEmpty else { return }
        let activeFolderDescriptors = sourcePathDescriptors(
            for: activeSources.filter { $0.kind == .folder }
        )
        for previousSource in supersededFileSources {
            let previousPath = mediaPathDescriptor(for: previousSource.url)
            guard activeFolderDescriptors.contains(where: {
                $0.covers(previousPath)
            }) else {
                continue
            }
            supersededThumbnailRootPaths.insert(
                previousSource.id.standardizedPath
            )
        }
    }

    private func sourcePathDescriptors(
        for sources: [MediaSource]
    ) -> [MediaSourcePathDescriptor] {
        let prioritizedSources = sources.filter { $0.kind == .file }
            + sources.filter { $0.kind == .folder }
        return prioritizedSources.map { source in
            let path = mediaPathDescriptor(for: source.url)
            return MediaSourcePathDescriptor(
                source: source,
                lexicalPathComponents: path.lexicalPathComponents,
                canonicalPathComponents: path.canonicalPathComponents
            )
        }
    }

    private func mediaPathDescriptor(for url: URL) -> MediaPathDescriptor {
        MediaPathDescriptor(
            lexicalPathComponents: url.standardizedFileURL.pathComponents,
            canonicalPathComponents: canonicalComparisonURL(url).pathComponents
        )
    }

    private func canonicalComparisonURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func stopPlaybackAndClearQueue() {
        playback.stop()
        loadedItemID = nil
        clearActiveQueue()
    }

    private func clearActiveQueue(
        preservingUnavailableItems: Bool = false
    ) {
        invalidateLoad()
        queue = nil
        playbackQueueMembership = .mediaLibrary
        currentItemID = nil
        queueItemsByID.removeAll()
        if !preservingUnavailableItems {
            replaceUnavailableItemIDs(with: [])
        }
        publishQueueChange()
    }

    private static func queueMembership(
        for playbackCollection: PlaybackCollection
    ) -> PlaybackQueueMembership {
        switch playbackCollection {
        case .mediaLibrary:
            .mediaLibrary
        case let .customPlaylist(id):
            .customPlaylist(id)
        case .fixed:
            .fixed
        }
    }

    private static func mediaItemsByID(
        _ items: [LibraryMediaItem]
    ) -> [LibraryMediaItem.ID: LibraryMediaItem] {
        var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        itemsByID.reserveCapacity(items.count)
        for item in items {
            itemsByID[item.id] = item
        }
        return itemsByID
    }

    private func installActiveSources(_ sources: [MediaSource]) {
        activeSources = sources
        monitoredFolderURLs = sources
            .filter { $0.kind == .folder }
            .map { $0.url.standardizedFileURL }
            .reduce(into: [String: URL]()) { urlsByPath, url in
                urlsByPath[url.path] = url
            }
            .values
            .sorted { $0.path < $1.path }
    }

    private func publishQueueChange(
        _ kind: QueueChangeKind = .structure
    ) {
        queueRevision &+= 1
        if kind == .structure {
            queueStructureRevision &+= 1
        }
    }

    private var currentLoadTaskRecord: LoadTaskRecord? {
        guard let currentLoadTaskID else {
            return nil
        }
        return loadTasks[currentLoadTaskID]
    }

    private func cancelCurrentScanTask() {
        guard let currentScanTaskID else {
            return
        }
        scanTasks[currentScanTaskID]?.cancel()
        self.currentScanTaskID = nil
        currentScanSourcePaths = nil
    }

    private func cancelAllScanTasks() -> [Task<Void, Never>] {
        scanGeneration &+= 1
        let tasks = Array(scanTasks.values)
        tasks.forEach { $0.cancel() }
        currentScanTaskID = nil
        currentScanSourcePaths = nil
        return tasks
    }

    private func finishScanTask(_ taskID: UUID) {
        scanTasks[taskID] = nil
        if currentScanTaskID == taskID {
            currentScanTaskID = nil
            currentScanSourcePaths = nil
        }
    }

    private func cancelCurrentLoadTask() {
        guard let currentLoadTaskID else {
            return
        }
        loadTasks[currentLoadTaskID]?.task.cancel()
        self.currentLoadTaskID = nil
    }

    private func cancelAllLoadTasks() -> [Task<Void, Never>] {
        loadGeneration &+= 1
        let tasks = loadTasks.values.map(\.task)
        tasks.forEach { $0.cancel() }
        currentLoadTaskID = nil
        return tasks
    }

    private func markLoadTaskNoLongerCurrent(_ taskID: UUID) {
        if currentLoadTaskID == taskID {
            currentLoadTaskID = nil
        }
    }

    private func finishLoadTask(_ taskID: UUID) {
        loadTasks[taskID] = nil
        markLoadTaskNoLongerCurrent(taskID)
    }

    private func invalidateLoad() {
        loadGeneration &+= 1
        cancelCurrentLoadTask()
    }

    private func loadCurrentItem(
        attemptsRemaining: Int,
        autoplay: Bool = true
    ) {
        guard !isShutDown,
              attemptsRemaining > 0,
              let currentItemID,
              let item = queueItemsByID[currentItemID] else {
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        cancelCurrentLoadTask()
        let outgoingProgress = playbackProgressCheckpoint()
        let transition = loadedItemID == nil
            ? PlaybackItemTransition.immediate
            : playback.queueTransitionStyle.playbackTransition
        loadedItemID = nil

        let source = ResolvedMediaSource(
            url: item.url,
            displayName: item.displayName
        )
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                finishLoadTask(taskID)
            }
            await savePlaybackProgress(outgoingProgress)
            guard generation == loadGeneration, !isShutDown else {
                return
            }
            let resumePosition = await resumablePosition(for: item.id)
            guard generation == loadGeneration, !isShutDown else {
                return
            }
            let result = await playback.load(
                source,
                autoplay: autoplay,
                initialPosition: resumePosition,
                transition: transition
            )
            guard generation == loadGeneration, !isShutDown else {
                return
            }
            markLoadTaskNoLongerCurrent(taskID)

            switch result {
            case .loaded:
                loadedItemID = item.id
                markItemAvailable(item.id)
                if resumePosition != nil, playback.currentTime == 0 {
                    try? await playbackProgressStore?.removeProgress(
                        for: [item.id]
                    )
                }
            case let .mediaFailure(failure):
                markItemUnavailable(item.id)
                let didAdvance = advanceAfterFailedLoad(
                    failedItemID: item.id,
                    attemptsRemaining: attemptsRemaining - 1,
                    autoplay: autoplay
                )
                if !didAdvance {
                    clearActiveQueue(preservingUnavailableItems: true)
                    playback.finishQueue(with: failure)
                    loadedItemID = nil
                }
            case .globalFailure:
                loadedItemID = nil
            case .cancelled:
                break
            }
        }
        loadTasks[taskID] = LoadTaskRecord(
            itemID: item.id,
            autoplay: autoplay,
            task: task
        )
        currentLoadTaskID = taskID
    }

    private func playbackProgressCheckpoint()
        -> PlaybackProgressCheckpoint? {
        guard playbackProgressStore != nil,
              let loadedItemID,
              visibleItemsByID[loadedItemID] != nil else {
            return nil
        }
        return PlaybackProgressCheckpoint(
            itemID: loadedItemID,
            position: playback.currentTime,
            duration: playback.duration
        )
    }

    private func savePlaybackProgress(
        _ checkpoint: PlaybackProgressCheckpoint?
    ) async {
        guard let checkpoint, let playbackProgressStore else {
            return
        }
        try? await playbackProgressStore.update(
            position: checkpoint.position,
            duration: checkpoint.duration,
            for: checkpoint.itemID
        )
    }

    private func resumablePosition(
        for itemID: LibraryMediaItem.ID
    ) async -> TimeInterval? {
        guard visibleItemsByID[itemID] != nil,
              let playbackProgressStore else {
            return nil
        }
        return try? await playbackProgressStore.position(for: itemID)
    }

    private func loadRestoredQueueItem(
        attemptsRemaining: Int,
        attachToPlayerSurface: Bool,
        expectedTemporaryPlaybackGeneration: UInt64? = nil
    ) async -> MediaLibraryQueueRestoreResult {
        var remainingAttempts = attemptsRemaining

        while remainingAttempts > 0 {
            guard !Task.isCancelled,
                  !isShutDown,
                  isCurrentTemporaryPlaybackGeneration(
                    expectedTemporaryPlaybackGeneration
                  ) else {
                return .cancelled
            }
            guard let currentItemID,
                  let item = queueItemsByID[currentItemID] else {
                return .temporarilyUnavailable
            }

            let source = ResolvedMediaSource(
                url: item.url,
                displayName: item.displayName
            )
            let result = await playback.load(
                source,
                autoplay: false,
                attachToPlayerSurface: attachToPlayerSurface
            )
            guard !Task.isCancelled,
                  !isShutDown,
                  isCurrentTemporaryPlaybackGeneration(
                    expectedTemporaryPlaybackGeneration
                  ) else {
                return .cancelled
            }

            switch result {
            case .loaded:
                loadedItemID = item.id
                markItemAvailable(item.id)
                return .restored
            case let .mediaFailure(failure):
                let isUnavailablePermanently = await isPermanentlyUnavailable(
                    item,
                    after: failure
                )
                guard !Task.isCancelled,
                      !isShutDown,
                      isCurrentTemporaryPlaybackGeneration(
                        expectedTemporaryPlaybackGeneration
                      ) else {
                    return .cancelled
                }
                guard isUnavailablePermanently else {
                    return .temporarilyUnavailable
                }

                markItemUnavailable(item.id)
                guard var queue else {
                    stopPlaybackAndClearQueue()
                    return .permanentlyUnavailable
                }
                let nextID = queue.remove([item.id])
                remainingAttempts = queue.count
                guard remainingAttempts > 0, let nextID else {
                    stopPlaybackAndClearQueue()
                    return .permanentlyUnavailable
                }
                self.queue = queue
                self.currentItemID = nextID
                publishQueueChange()
            case .globalFailure:
                loadedItemID = nil
                return .temporarilyUnavailable
            case .cancelled:
                return .cancelled
            }
        }

        guard isCurrentTemporaryPlaybackGeneration(
            expectedTemporaryPlaybackGeneration
        ) else {
            return .cancelled
        }
        stopPlaybackAndClearQueue()
        return .permanentlyUnavailable
    }

    private func isCurrentTemporaryPlaybackGeneration(
        _ expectedGeneration: UInt64?
    ) -> Bool {
        expectedGeneration.map { $0 == temporaryPlaybackGeneration } ?? true
    }

    private func isPermanentlyUnavailable(
        _ item: LibraryMediaItem,
        after failure: PlaybackFailure
    ) async -> Bool {
        switch failure {
        case .unsupported:
            return true
        case .cannotOpen:
            return await scanner.availability(of: item) == .missing
        case .surfaceTimeout:
            return false
        }
    }

    @discardableResult
    private func advanceAfterFailedLoad(
        failedItemID: LibraryMediaItem.ID,
        attemptsRemaining: Int,
        autoplay: Bool
    ) -> Bool {
        guard attemptsRemaining > 0, var queue,
              let nextID = nextAvailableItem(
                  in: &queue,
                  maximumAdvances: attemptsRemaining,
                  excluding: failedItemID
              ) else {
            return false
        }

        self.queue = queue
        currentItemID = nextID
        publishQueueChange(.cursor)
        loadCurrentItem(
            attemptsRemaining: attemptsRemaining,
            autoplay: autoplay
        )
        return true
    }

    private func handleItemEnded() -> PlaybackItemEndDisposition {
        guard let queue, !isShutDown else {
            return .unhandled
        }
        if queue.count == 1 || playbackRepeatBehavior == .currentItem {
            return .repeatCurrent
        }
        return advanceToNextItem() ? .advanced : .unhandled
    }

    private func handleItemFailure() -> Bool {
        guard !isShutDown,
              let failedItemID = currentItemID,
              var queue else {
            return false
        }

        markItemUnavailable(failedItemID)
        let queueCount = queue.count
        guard let nextID = nextAvailableItem(
            in: &queue,
            maximumAdvances: queueCount,
            excluding: failedItemID
        ) else {
            clearActiveQueue(preservingUnavailableItems: true)
            return false
        }

        self.queue = queue
        currentItemID = nextID
        publishQueueChange(.cursor)
        loadCurrentItem(attemptsRemaining: queueCount)
        return true
    }

    private func nextAvailableItem(
        in queue: inout PlaybackQueue<LibraryMediaItem.ID>,
        maximumAdvances: Int,
        excluding excludedItemID: LibraryMediaItem.ID? = nil
    ) -> LibraryMediaItem.ID? {
        guard maximumAdvances > 0 else {
            return nil
        }

        for _ in 0..<maximumAdvances {
            guard let candidateID = queue.moveToNext() else {
                return nil
            }
            guard candidateID != excludedItemID,
                  !unavailableItemIDs.contains(candidateID) else {
                continue
            }
            return candidateID
        }
        return nil
    }
}

extension MediaLibraryCoordinator: MediaLibraryAutomaticRefreshTarget {
    var automaticRefreshIsScanning: Bool {
        scanState == .scanning
    }

    @discardableResult
    func requestAutomaticRefresh() -> Bool {
        guard canRefresh else {
            return false
        }
        refresh()
        return scanState == .scanning
    }
}
