import Combine
import Foundation

enum MediaLibraryScanState: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case failed
}

enum MediaLibraryStartDisposition: Equatable, Sendable {
    case scanStarted
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
}

typealias RestoredPlaybackQueueShuffler = @MainActor (
    inout PlaybackQueue<LibraryMediaItem.ID>
) -> Void

@MainActor
final class MediaLibraryCoordinator: ObservableObject {
    private enum QueueChangeKind {
        case cursor
        case structure
    }

    private enum PlaybackQueueMembership: Equatable {
        case mediaLibrary
        case external
    }

    private struct LoadTaskRecord {
        let itemID: LibraryMediaItem.ID
        let autoplay: Bool
        let task: Task<Void, Never>
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

    private struct CanonicalItemLookupIndex {
        struct RootResolution {
            let rootURL: URL
            let canonicalPath: String
        }

        let itemsRevision: UInt64
        let itemIDsByCanonicalPath: [String: LibraryMediaItem.ID]
        let rootResolutions: [RootResolution]
    }

    @Published private(set) var scanState: MediaLibraryScanState = .idle
    @Published private(set) var roots: [MediaLibraryRoot] = []
    @Published private(set) var items: [LibraryMediaItem] = []
    private(set) var itemsRevision: UInt64 = 0
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
    @Published private(set) var importNotice: MediaImportNotice?
    @Published private(set) var externalPlaybackNotice:
        ExternalPlaybackNotice?
    @Published private(set) var isExternalPlaybackContext = false
    @Published private(set) var temporaryItemIDs:
        Set<LibraryMediaItem.ID> = []
    @Published private(set) var sourceAccessState:
        MediaLibrarySourceAccessState = .empty

    var currentItem: LibraryMediaItem? {
        guard let currentItemID else {
            return nil
        }
        return queueItemsByID[currentItemID]
            ?? visibleItemsByID[currentItemID]
    }

    func libraryItem(matching url: URL) -> LibraryMediaItem? {
        guard url.isFileURL else {
            return nil
        }
        return firstItem(matching: [url])
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
            && sourceAccessState.hasUnavailableSources
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
    private let preferencesStore: (any AppPreferencesStoring)?
    private let reshuffleRestoredQueue: RestoredPlaybackQueueShuffler
    private let temporaryPlaybackSession: TemporaryPlaybackSession

    private var activeSources: [MediaSource] = []
    private var incompleteRootPaths: Set<String> = []
    private var visibleItemsByID: [
        LibraryMediaItem.ID: LibraryMediaItem
    ] = [:]
    private var canonicalItemLookupIndex: CanonicalItemLookupIndex?
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
    private var queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var currentScanTaskID: UUID?
    private var currentScanSourcePaths: Set<String>?
    private var sortTasks: [UUID: Task<Void, Never>] = [:]
    private var currentSortTaskID: UUID?
    private var loadTasks: [UUID: LoadTaskRecord] = [:]
    private var currentLoadTaskID: UUID?
    private var loadedItemID: LibraryMediaItem.ID?
    private var rootIDsPendingRemoval: Set<MediaLibraryRoot.ID> = []
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
        reshuffleRestoredQueue: @escaping RestoredPlaybackQueueShuffler = {
            $0.reshufflePendingItems()
        }
    ) {
        self.playback = playback
        self.sourceSelector = sourceSelector
        self.mediaSession = mediaSession
        self.scanner = scanner
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.snapshotPreparer = snapshotPreparer
        temporaryPlaybackSession = TemporaryPlaybackSession(
            scanner: scanner
        )
        self.playbackOrder = playbackOrder
        self.playbackRepeatBehavior = playbackRepeatBehavior
        self.sort = sort
        self.preferencesStore = preferencesStore
        self.reshuffleRestoredQueue = reshuffleRestoredQueue

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
        activeSources = restoredSources
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
    private func selectMediaSources(
        intent: MediaSourceSelectionIntent,
        autoplayExplicitFiles: Bool
    ) -> MediaLibraryStartDisposition? {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return nil
        }
        let selectedURLs = sourceSelector.selectSources(for: intent)
        guard let preparation = prepareImport(selectedURLs) else {
            return nil
        }
        commitImport(
            preparation,
            autoplayExplicitFiles: autoplayExplicitFiles
        )
        return scanState == .scanning ? .scanStarted : .alreadyStarted
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
            let requestedFileMatches = items(matching: requestedFileURLs)
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
            generation: importGeneration
        )
    }

    func commitImport(
        _ preparation: MediaLibraryImportPreparation,
        autoplayExplicitFiles: Bool = true
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

        let explicitFileMatches = items(matching: explicitFileURLs)
        let everyExplicitFileIsVisible = !explicitFileURLs.isEmpty
            && explicitFileMatches.allSatisfy { $0 != nil }
        if everyExplicitFileIsVisible,
           let existingItem = firstItem(matching: pendingAutoplayFileURLs) {
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
        play(libraryItem, queueMembership: .mediaLibrary)
        if endedExternalPlaybackContext {
            publishQueueChange(.cursor)
        }
    }

    func capturePlaybackContext() -> MediaLibraryPlaybackContext? {
        guard let queueSnapshot = makeQueueSnapshot() else {
            return nil
        }
        return MediaLibraryPlaybackContext(
            queueSnapshot: queueSnapshot,
            queueItemsByID: queueItemsByID,
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
        temporaryPlaybackGeneration &+= 1
        let generation = temporaryPlaybackGeneration

        let resolution: TemporaryPlaybackResolution
        do {
            resolution = try await temporaryPlaybackSession.resolve(
                urls,
                libraryItems: items
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
        let resolvedItemsByID = Dictionary(
            uniqueKeysWithValues: resolution.items.map { ($0.id, $0) }
        )
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
        playbackQueueMembership = .mediaLibrary
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
        invalidateSourceAccessOperation()
        invalidatePendingImport()
        defer {
            rootIDsPendingRemoval.remove(root.id)
        }

        // Capture source ownership, then persist the user's decision before
        // cancelling consumers. Keep the active security scope until every
        // scanner, thumbnail request, and playback load has drained.
        let removedSource = MediaSource(url: root.url, kind: root.kind)
        let pendingRemovalPaths = Set(
            rootIDsPendingRemoval.map(\.standardizedPath)
        )
        let remainingActiveSources = mediaSession.restoreSources().filter {
            !pendingRemovalPaths.contains($0.id.standardizedPath)
        }
        mediaSession.prepareToRemoveSource(removedSource)
        let removedRootPath = root.id.standardizedPath
        let removedSourceDescriptor = sourcePathDescriptors(
            for: [removedSource]
        )[0]
        let remainingSourceDescriptors = sourcePathDescriptors(
            for: remainingActiveSources
        )
        var mediaPathDescriptorsByPath: [String: MediaPathDescriptor] = [:]
        func descriptor(for mediaURL: URL) -> MediaPathDescriptor {
            let standardizedPath = mediaURL.standardizedFileURL.path
            if let descriptor = mediaPathDescriptorsByPath[standardizedPath] {
                return descriptor
            }
            let descriptor = mediaPathDescriptor(for: mediaURL)
            mediaPathDescriptorsByPath[standardizedPath] = descriptor
            return descriptor
        }
        let knownItems = Array(queueItemsByID.values) + items
        let removedItems = knownItems.filter { item in
            let itemRootPath = descriptor(for: item.rootURL)
            return removedSourceDescriptor.covers(itemRootPath)
                && !remainingSourceDescriptors.contains { activeSource in
                    activeSource.covers(itemRootPath)
                }
        }
        let removedItemIDs = Set(removedItems.map(\.id))
        let supersededRootPathsBeingRemoved = supersededThumbnailRootPaths
            .filter {
                removedSourceDescriptor.covers(
                    descriptor(for: URL(fileURLWithPath: $0))
                )
            }
        let removedThumbnailRootIDs = Set(
            removedItems.map {
                MediaLibraryRoot.ID(standardizedPath: $0.id.rootPath)
            }
        ).union(
            supersededRootPathsBeingRemoved.map {
                MediaLibraryRoot.ID(standardizedPath: $0)
            }
        ).union([root.id])

        let scanTasksToDrain = cancelAllScanTasks()
        let playbackTouchesRemovedItems =
            loadedItemID.map(removedItemIDs.contains) == true
            || loadTasks.values.contains {
                removedItemIDs.contains($0.itemID)
            }
            || (
                currentItemID.map(removedItemIDs.contains) == true
                    && playback.readiness != .empty
            )
        let shouldAutoplayAfterDrain = playback.isPlaybackRequested
            || currentLoadTaskRecord?.autoplay == true
        let loadTasksToDrain: [Task<Void, Never>]
        if playbackTouchesRemovedItems {
            loadTasksToDrain = cancelAllLoadTasks()
            playback.stop()
            loadedItemID = nil
        } else {
            loadTasksToDrain = []
        }

        roots.removeAll {
            $0.id == root.id
        }
        replaceItems(
            with: items.filter { !removedItemIDs.contains($0.id) }
        )
        replaceUnavailableItemIDs(
            with: unavailableItemIDs.subtracting(removedItemIDs)
        )
        for itemID in removedItemIDs {
            queueItemsByID[itemID] = nil
        }
        activeSources.removeAll {
            $0.id.standardizedPath == removedRootPath
        }

        let removedCurrentItem = removeItemsFromActiveQueue(removedItemIDs)
        let expectedReloadItemID = currentItemID
        let reloadGeneration = loadGeneration

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
        for task in loadTasksToDrain {
            await task.value
        }
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

        activeSources = remainingSources
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
        play(item, queueMembership: playbackQueueMembership)
    }

    private func play(
        _ item: LibraryMediaItem,
        queueMembership: PlaybackQueueMembership
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

        if var activeQueue = queue {
            let synchronizedIDs: [LibraryMediaItem.ID]
            if queueMembership == .external {
                synchronizedIDs = activeQueue.items + [item.id]
                queueItemsByID[item.id] = item
            } else {
                synchronizedIDs = items.map(\.id)
                queueItemsByID.merge(visibleItemsByID) { _, visible in
                    visible
                }
            }
            let currentItemBeforeSynchronization = activeQueue.currentItem
            let structureChanged = activeQueue.synchronizeItems(
                synchronizedIDs
            )
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

            if structureChanged || cursorChanged {
                queue = activeQueue
                currentItemID = activeQueue.currentItem
                publishQueueChange(
                    structureChanged ? .structure : .cursor
                )
            }
            markItemAvailable(item.id)
            if cursorChanged || loadedItemID != item.id {
                loadCurrentItem(attemptsRemaining: activeQueue.count)
            } else {
                playback.setPlaybackIntent(.playing)
            }
            return
        }

        let playbackItems = items
        guard !playbackItems.isEmpty else {
            return
        }
        playbackQueueMembership = .mediaLibrary
        queueItemsByID = visibleItemsByID
        let itemIDs = playbackItems.map(\.id)
        queue = PlaybackQueue(
            items: itemIDs,
            startingAt: item.id,
            order: playbackOrder
        )
        currentItemID = queue?.currentItem
        publishQueueChange()
        markItemAvailable(item.id)
        loadCurrentItem(attemptsRemaining: itemIDs.count)
    }

    @discardableResult
    func playNext() -> Bool {
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
            replaceItems(with: sort.sorted(items))
            return
        }

        let baseItemsRevision = itemsRevision
        let baseItems = items
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
                    baseItems,
                    using: requestedSort
                )
                try Task.checkCancellation()
                guard !isShutDown,
                      generation == sortGeneration,
                      baseItemsRevision == itemsRevision,
                      requestedSort == sort else {
                    return
                }
                replaceItems(with: prepared)
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
        attachToPlayerSurface: Bool = false
    ) async -> MediaLibraryQueueRestoreResult {
        guard !Task.isCancelled,
              !isShutDown,
              rootIDsPendingRemoval.isEmpty else {
            return .cancelled
        }
        guard scanState == .ready else {
            return .temporarilyUnavailable
        }
        let availableItemsByID = visibleItemsByID
        let canonicalSnapshot = remappedQueueSnapshot(
            snapshot,
            using: availableItemsByID
        )
        guard var restoredQueue = PlaybackQueue(
            snapshot: canonicalSnapshot
        ) else {
            return .permanentlyUnavailable
        }
        var missingItemIDs: Set<LibraryMediaItem.ID> = []
        for itemID in snapshot.items where visibleItemsByID[itemID] == nil {
            missingItemIDs.insert(itemID)
        }
        if !missingItemIDs.isEmpty {
            let requestedRootPaths = Set(
                activeSources.map { $0.id.standardizedPath }
            )
            let missingMediaPathComponents = Set(
                missingItemIDs.map(\.standardizedMediaPath)
            ).map {
                LexicalPathCoverageIndex.pathComponents(for: $0)
            }
            let incompleteRootCoverage = LexicalPathCoverageIndex(
                sourcePaths: incompleteRootPaths
            )
            let requestedRootCoverage = LexicalPathCoverageIndex(
                sourcePaths: requestedRootPaths
            )
            let visibleRootCoverage = LexicalPathCoverageIndex(
                sourcePaths: roots.map(\.id.standardizedPath)
            )
            let hasIncompleteRoot = missingMediaPathComponents.contains {
                incompleteRootCoverage.covers(mediaPathComponents: $0)
            }
            let hasUnavailableRequestedRoot = missingMediaPathComponents
                .contains {
                    requestedRootCoverage.covers(mediaPathComponents: $0)
                        && !visibleRootCoverage.covers(
                            mediaPathComponents: $0
                        )
                }
            let hasPossiblyUnavailableUnresolvedRoot =
                mediaSession.hasUnavailablePersistedSources
                    && missingMediaPathComponents.contains {
                        !visibleRootCoverage.covers(mediaPathComponents: $0)
                    }
            if hasIncompleteRoot
                || hasUnavailableRequestedRoot
                || hasPossiblyUnavailableUnresolvedRoot {
                return .temporarilyUnavailable
            }
        }

        invalidateLoad()
        if !missingItemIDs.isEmpty {
            _ = restoredQueue.remove(missingItemIDs)
        }
        guard !restoredQueue.isEmpty,
              let restoredItemID = restoredQueue.currentItem else {
            stopPlaybackAndClearQueue()
            return .permanentlyUnavailable
        }

        // The cached global mode is the runtime truth. A real process restore
        // also refreshes the unplayed part of an existing shuffled round.
        if restoredQueue.order != playbackOrder {
            restoredQueue.setOrder(playbackOrder)
        } else if playbackOrder == .shuffled {
            reshuffleRestoredQueue(&restoredQueue)
        }

        queueItemsByID = availableItemsByID
        playbackQueueMembership = .mediaLibrary
        queue = restoredQueue
        currentItemID = restoredItemID
        publishQueueChange()
        replaceUnavailableItemIDs(
            with: unavailableItemIDs.intersection(availableItemsByID.keys)
        )

        return await loadRestoredQueueItem(
            attemptsRemaining: restoredQueue.count,
            attachToPlayerSurface: attachToPlayerSurface
        )
    }

    func discardRestoredQueue() {
        stopPlaybackAndClearQueue()
    }

    func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true
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
        for task in pendingSortTasks {
            await task.value
        }

        mediaSession.stop()
        activeSources = []
        latestPreparedSources = []
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
        activeSources = sources
        updateSourceAccessState(using: sources)
        scanState = .scanning

        let taskID = UUID()
        currentScanSourcePaths = sourcePathSet(sources)
        let candidateSources = candidateFileURLs.map {
            MediaSource(url: $0, kind: .file)
        }
        let task = Task { [weak self, scanner] in
            defer {
                self?.finishScanTask(taskID)
            }
            do {
                var snapshotForAllSources: MediaLibrarySnapshot?
                var didFulfillExplicitIntent = false
                if !candidateSources.isEmpty {
                    do {
                        let candidateSnapshot = try await scanner.scan(
                            sources: candidateSources
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
                        if isExplicitIntentCurrent(
                            explicitIntentGeneration
                        ), let candidate = firstItem(
                            matching: autoplayFileURLs,
                            in: representedCandidates
                        ) {
                            activateImportedItem(
                                candidate,
                                expandQueue: expandQueueForExplicitImport
                            )
                            clearPendingExplicitImport(
                                matching: explicitIntentGeneration
                            )
                            didFulfillExplicitIntent = true
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
                    try await scanner.scan(sources: sources)
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
                    if let candidate = firstItem(
                        matching: autoplayFileURLs
                    ) {
                        activateImportedItem(
                            candidate,
                            expandQueue: expandQueueForExplicitImport
                        )
                    }
                    clearPendingExplicitImport(
                        matching: explicitIntentGeneration
                    )
                }
                if let importGeneration,
                   importGeneration == self.importGeneration,
                   sourcePathSet(sources)
                    == sourcePathSet(latestPreparedSources) {
                    preparedSourcesNeedRefresh = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                scanState = .failed
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
        while true {
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }

            let requestedSort = sort
            let prepared = try await snapshotPreparer.prepare(
                snapshot,
                requestedSourcePaths: requestedSourcePaths,
                sort: requestedSort
            )
            try Task.checkCancellation()
            guard generation == scanGeneration, !isShutDown else {
                throw CancellationError()
            }
            guard sort == requestedSort else {
                continue
            }

            var preparedQueue:
                PreparedMediaLibraryQueueReconciliation?
            while let queueSnapshot = makeQueueSnapshot() {
                let capturedQueueStateRevision = queueStateRevision
                let reconciliation = try await snapshotPreparer
                    .reconcileQueue(
                        snapshot: queueSnapshot,
                        queueItemsByID: queueItemsByID,
                        availableItemsByID: prepared.library.itemsByID
                    )
                try Task.checkCancellation()
                guard generation == scanGeneration, !isShutDown else {
                    throw CancellationError()
                }
                guard sort == requestedSort else {
                    break
                }
                guard capturedQueueStateRevision == queueStateRevision else {
                    continue
                }
                preparedQueue = reconciliation
                break
            }
            guard sort == requestedSort else {
                continue
            }

            mediaThumbnailProvider.allowThumbnails(
                forRootIDs: Set(prepared.roots.map(\.id))
            )
            if roots != prepared.roots {
                roots = prepared.roots
            }
            replaceItems(with: prepared.library)
            incompleteRootPaths = prepared.incompleteRootPaths
            let wasTemporaryPlayback = !temporaryItemIDs.isEmpty
            let previousCurrentItemID = currentItemID
            let shouldAutoplayAfterReconciliation =
                playback.isPlaybackRequested
                    || currentLoadTaskRecord?.autoplay == true

            var visibleUnavailableItemIDs = Set(
                unavailableItemIDs.compactMap {
                    prepared.library.itemsByID[$0]?.id
                }
            )
            var queueChanged = false
            if let preparedQueue {
                queueItemsByID = preparedQueue.queueItemsByID
                if preparedQueue.requiresQueueReplacement,
                   let replacementQueue = preparedQueue.replacementQueue {
                    queue = replacementQueue
                    currentItemID = preparedQueue.currentItemID
                    loadedItemID = loadedItemID.map {
                        prepared.library.itemsByID[$0]?.id ?? $0
                    }
                    visibleUnavailableItemIDs = Set(
                        visibleUnavailableItemIDs.map {
                            prepared.library.itemsByID[$0]?.id ?? $0
                        }
                    )
                    queueChanged = true
                }
            }
            queueItemsByID.merge(prepared.library.itemsByID) {
                _, visibleItem in visibleItem
            }
            if playbackQueueMembership == .mediaLibrary,
               var activeQueue = queue {
                let synchronizedItemIDs = synchronizedQueueItemIDs(
                    activeQueue,
                    availableItems: prepared.library.items,
                    availableItemsByID: prepared.library.itemsByID,
                    roots: prepared.roots,
                    incompleteRootPaths: prepared.incompleteRootPaths
                )
                if activeQueue.synchronizeItems(synchronizedItemIDs) {
                    if activeQueue.isEmpty {
                        queue = nil
                        currentItemID = nil
                    } else {
                        queue = activeQueue
                        currentItemID = activeQueue.currentItem
                    }
                    queueChanged = true
                }
            }
            if let activeQueue = queue {
                let activeItemIDs = Set(activeQueue.items)
                queueItemsByID = queueItemsByID.filter {
                    activeItemIDs.contains($0.key)
                }
            } else if queueChanged {
                queueItemsByID.removeAll()
            }
            temporaryItemIDs.subtract(prepared.library.itemsByID.keys)
            if wasTemporaryPlayback, temporaryItemIDs.isEmpty {
                temporaryPlaybackSession.end()
            }
            if queueChanged {
                publishQueueChange()
            }
            replaceUnavailableItemIDs(with: visibleUnavailableItemIDs)
            if previousCurrentItemID != currentItemID {
                invalidateLoad()
                playback.stop()
                loadedItemID = nil
                if queue != nil {
                    loadCurrentItem(
                        attemptsRemaining: queue?.count ?? 0,
                        autoplay: shouldAutoplayAfterReconciliation
                    )
                }
            }
            if requestedSourcePaths == sourcePathSet(latestPreparedSources) {
                preparedSourcesNeedRefresh = false
            }
            scanState = .ready
            return
        }
    }

    private func synchronizedQueueItemIDs(
        _ queue: PlaybackQueue<LibraryMediaItem.ID>,
        availableItems: [LibraryMediaItem],
        availableItemsByID: [LibraryMediaItem.ID: LibraryMediaItem],
        roots: [MediaLibraryRoot],
        incompleteRootPaths: Set<String>
    ) -> [LibraryMediaItem.ID] {
        let completeRootPaths = roots.lazy
            .map(\.id.standardizedPath)
            .filter { !incompleteRootPaths.contains($0) }
        let completeRootCoverage = LexicalPathCoverageIndex(
            sourcePaths: completeRootPaths
        )
        let retainedMissingItemIDs = queue.items.filter { itemID in
            guard availableItemsByID[itemID] == nil,
                  let queuedItem = queueItemsByID[itemID] else {
                return false
            }
            let mediaPathComponents = LexicalPathCoverageIndex.pathComponents(
                for: queuedItem.id.standardizedMediaPath
            )
            return !completeRootCoverage.covers(
                mediaPathComponents: mediaPathComponents
            )
        }
        return availableItems.map(\.id) + retainedMissingItemIDs
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
    private func replaceItems(with items: [LibraryMediaItem]) -> Bool {
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
                itemsByID: itemsByID
            )
        )
    }

    @discardableResult
    private func replaceItems(
        with prepared: PreparedMediaLibraryItems
    ) -> Bool {
        guard items != prepared.items else {
            return false
        }
        visibleItemsByID = prepared.itemsByID
        canonicalItemLookupIndex = nil
        itemsRevision &+= 1
        items = prepared.items
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
                    fileSize: candidate.fileSize
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
                fileSize: candidate.fileSize
            )
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
            : Dictionary(
                uniqueKeysWithValues: candidateItems.map { ($0.id, $0) }
            )
        var matches = fileURLs.map {
            candidatesByID[LibraryMediaItem.ID(mediaURL: $0)]
        }
        guard matches.contains(where: { $0 == nil }) else {
            return matches
        }

        let canonicalIndex = if candidates == nil {
            canonicalItemLookupIndexForVisibleItems()
        } else {
            makeCanonicalItemLookupIndex(
                for: candidateItems,
                itemsRevision: itemsRevision
            )
        }
        for index in fileURLs.indices where matches[index] == nil {
            let comparisonPath = canonicalComparisonURL(
                fileURLs[index]
            ).path
            if let itemID = canonicalIndex
                .itemIDsByCanonicalPath[comparisonPath] {
                matches[index] = candidatesByID[itemID]
            }
        }
        return matches
    }

    private func canonicalItemLookupIndexForVisibleItems()
        -> CanonicalItemLookupIndex {
        // A root symlink can be retargeted without publishing new items.
        // Revalidate only the roots before reusing the large item index.
        if let canonicalItemLookupIndex,
           canonicalItemLookupIndex.itemsRevision == itemsRevision,
           canonicalItemLookupIndex.rootResolutions.allSatisfy({ resolution in
               canonicalComparisonURL(resolution.rootURL).path
                   == resolution.canonicalPath
           }) {
            return canonicalItemLookupIndex
        }

        let index = makeCanonicalItemLookupIndex(
            for: items,
            itemsRevision: itemsRevision
        )
        canonicalItemLookupIndex = index
#if DEBUG
        canonicalItemLookupIndexBuildCountForTesting += 1
#endif
        return index
    }

    private func makeCanonicalItemLookupIndex(
        for candidateItems: [LibraryMediaItem],
        itemsRevision: UInt64
    ) -> CanonicalItemLookupIndex {
        var itemIDsByCanonicalPath: [String: LibraryMediaItem.ID] = [:]
        var canonicalRootURLsByPath: [String: URL] = [:]
        var rootResolutions: [CanonicalItemLookupIndex.RootResolution] = []
        itemIDsByCanonicalPath.reserveCapacity(candidateItems.count)
        for item in candidateItems {
            let rootPath = item.rootURL.standardizedFileURL.path
            let canonicalRootURL: URL
            if let cachedRootURL = canonicalRootURLsByPath[rootPath] {
                canonicalRootURL = cachedRootURL
            } else {
                canonicalRootURL = canonicalComparisonURL(item.rootURL)
                canonicalRootURLsByPath[rootPath] = canonicalRootURL
                rootResolutions.append(
                    CanonicalItemLookupIndex.RootResolution(
                        rootURL: item.rootURL,
                        canonicalPath: canonicalRootURL.path
                    )
                )
            }
            let canonicalItemURL = if item.relativePath.isEmpty {
                canonicalRootURL
            } else {
                canonicalRootURL.appendingPathComponent(item.relativePath)
            }
            itemIDsByCanonicalPath[
                canonicalItemURL.standardizedFileURL.path
            ] = item.id
        }
        return CanonicalItemLookupIndex(
            itemsRevision: itemsRevision,
            itemIDsByCanonicalPath: itemIDsByCanonicalPath,
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
            play(item)
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
        var reconciledItemsByID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ] = [:]
        for (queuedItemID, queuedItem) in queueItemsByID {
            let item = availableItemsByID[queuedItemID] ?? queuedItem
            reconciledItemsByID[item.id] = item
        }
        queueItemsByID = reconciledItemsByID

        guard queue != nil else {
            return
        }
        guard let snapshot = makeQueueSnapshot() else {
            return
        }
        let remappedSnapshot = remappedQueueSnapshot(
            snapshot,
            using: availableItemsByID
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
            availableItemsByID[$0]?.id ?? $0
        }
        replaceUnavailableItemIDs(
            with: Set(unavailableItemIDs.map {
                availableItemsByID[$0]?.id ?? $0
            })
        )
        publishQueueChange()
    }

    private func remappedQueueSnapshot(
        _ snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        using availableItemsByID: [
            LibraryMediaItem.ID: LibraryMediaItem
        ]
    ) -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        func canonicalID(
            _ id: LibraryMediaItem.ID
        ) -> LibraryMediaItem.ID {
            availableItemsByID[id]?.id ?? id
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
        if mediaSession.hasUnavailablePersistedSources {
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
        let activeFolderDescriptors = sourcePathDescriptors(
            for: activeSources.filter { $0.kind == .folder }
        )
        for previousSource in previousSources where previousSource.kind == .file {
            guard !activeSourceIDs.contains(previousSource.id) else {
                continue
            }
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

    @discardableResult
    private func removeItemsFromActiveQueue(
        _ removedItemIDs: Set<LibraryMediaItem.ID>
    ) -> Bool {
        guard !removedItemIDs.isEmpty, var queue else {
            return false
        }

        let removedCurrentItem = currentItemID.map {
            removedItemIDs.contains($0)
        } == true
        var nextItemID = queue.remove(removedItemIDs)

        if removedCurrentItem,
           let candidateItemID = nextItemID,
           unavailableItemIDs.contains(candidateItemID) {
            nextItemID = nextAvailableItem(
                in: &queue,
                maximumAdvances: queue.count,
                excluding: candidateItemID
            )
        }

        guard !queue.isEmpty, let nextItemID else {
            clearActiveQueue()
            return removedCurrentItem
        }

        self.queue = queue
        publishQueueChange()
        guard removedCurrentItem else {
            return false
        }

        currentItemID = nextItemID
        return true
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
            let result = await playback.load(
                source,
                autoplay: autoplay
            )
            guard generation == loadGeneration, !isShutDown else {
                return
            }
            markLoadTaskNoLongerCurrent(taskID)

            switch result {
            case .loaded:
                loadedItemID = item.id
                markItemAvailable(item.id)
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
        return playNext() ? .advanced : .unhandled
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
