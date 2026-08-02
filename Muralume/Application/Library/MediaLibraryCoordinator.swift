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

    var localizedKey: String {
        switch self {
        case .partialFailure:
            "library.import.partial"
        case .failure:
            "library.import.failed"
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

    @Published private(set) var scanState: MediaLibraryScanState = .idle
    @Published private(set) var roots: [MediaLibraryRoot] = []
    @Published private(set) var items: [LibraryMediaItem] = []
    @Published private(set) var playbackOrder: PlaybackOrder
    @Published private(set) var sort: MediaLibrarySort
    @Published private(set) var currentItemID: LibraryMediaItem.ID?
    @Published private(set) var unavailableItemIDs: Set<LibraryMediaItem.ID> = []
    @Published private(set) var queueRevision: UInt64 = 0
    @Published private(set) var importNotice: MediaImportNotice?

    var currentItem: LibraryMediaItem? {
        guard let currentItemID else {
            return nil
        }
        return queueItemsByID[currentItemID]
            ?? items.first { $0.id == currentItemID }
    }

    var currentPosition: Int? {
        queue?.currentRoundPosition
    }

    var queueCount: Int {
        queue?.count ?? 0
    }

    var hasActiveQueue: Bool {
        queue != nil
    }

    var canMoveToPrevious: Bool {
        queue?.canMoveToPrevious == true
    }

    private let playback: PlaybackCoordinator
    private let sourceSelector: any MediaSourceSelecting
    private let mediaSession: any MediaAccessSession
    private let scanner: any MediaLibraryScanning
    private let mediaThumbnailProvider: any MediaThumbnailProviding
    private let preferencesStore: (any AppPreferencesStoring)?
    private let reshuffleRestoredQueue: RestoredPlaybackQueueShuffler

    private var activeSources: [MediaSource] = []
    private var incompleteRootPaths: Set<String> = []
    private var queue: PlaybackQueue<LibraryMediaItem.ID>?
    private var queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var currentScanTaskID: UUID?
    private var currentScanSourcePaths: Set<String>?
    private var loadTasks: [UUID: LoadTaskRecord] = [:]
    private var currentLoadTaskID: UUID?
    private var loadedItemID: LibraryMediaItem.ID?
    private var rootIDsPendingRemoval: Set<MediaLibraryRoot.ID> = []
    private var scanGeneration: UInt64 = 0
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

    init(
        playback: PlaybackCoordinator,
        sourceSelector: any MediaSourceSelecting,
        mediaSession: any MediaAccessSession,
        scanner: any MediaLibraryScanning,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        playbackOrder: PlaybackOrder,
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
        self.playbackOrder = playbackOrder
        self.sort = sort
        self.preferencesStore = preferencesStore
        self.reshuffleRestoredQueue = reshuffleRestoredQueue

        playback.itemEndedHandler = { [weak self] in
            self?.handleItemEnded() ?? false
        }
        playback.itemFailureHandler = { [weak self] _ in
            self?.handleItemFailure() ?? false
        }
    }

    @discardableResult
    func start() -> MediaLibraryStartDisposition {
        guard !hasStarted, !isShutDown else {
            return .alreadyStarted
        }
        hasStarted = true

        let restoredSources = mediaSession.restoreSources()
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

    func addVideos() {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return
        }
        let selectedURLs = sourceSelector.selectVideos()
        guard let preparation = prepareImport(
            selectedURLs,
            autoplayFirstExplicitFile: true
        ) else {
            return
        }
        commitImport(preparation)
    }

    func addFolders() {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return
        }
        let selectedURLs = sourceSelector.selectFolders()
        guard let preparation = prepareImport(
            selectedURLs,
            autoplayFirstExplicitFile: false
        ) else {
            return
        }

        commitImport(preparation)
    }

    func prepareImport(
        _ selectedURLs: [URL],
        autoplayFirstExplicitFile: Bool
    ) -> MediaLibraryImportPreparation? {
        guard !isShutDown,
              rootIDsPendingRemoval.isEmpty,
              !selectedURLs.isEmpty else {
            return nil
        }

        let previouslyPreparedSources = latestPreparedSources.isEmpty
            ? activeSources
            : latestPreparedSources
        let update = mediaSession.addSources(selectedURLs)
        if update.acceptedRequestCount == 0 {
            importNotice = .failure
            return nil
        }
        importNotice = update.rejectedRequestCount > 0
            ? .partialFailure
            : nil

        let requestedFileURLs = autoplayFirstExplicitFile
            ? update.requestedFileURLs
            : []
        recordSupersededThumbnailRoots(
            previousSources: previouslyPreparedSources,
            activeSources: update.activeSources
        )
        latestPreparedSources = update.activeSources
        preparedSourcesNeedRefresh =
            preparedSourcesNeedRefresh || update.didChangeSources
        if !requestedFileURLs.isEmpty {
            pendingExplicitImportNeedsQueueExpansion =
                pendingExplicitImportNeedsQueueExpansion
                    || requestedFileURLs.contains {
                        firstItem(matching: [$0]) == nil
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

        let everyExplicitFileIsVisible = !explicitFileURLs.isEmpty
            && explicitFileURLs.allSatisfy {
                firstItem(matching: [$0]) != nil
            }
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

    func removeRoot(_ root: MediaLibraryRoot) async {
        guard !isShutDown,
              roots.contains(where: { $0.id == root.id }),
              rootIDsPendingRemoval.insert(root.id).inserted else {
            return
        }
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
        items.removeAll {
            removedItemIDs.contains($0.id)
        }
        unavailableItemIDs.subtract(removedItemIDs)
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
        guard !activeSources.isEmpty, rootIDsPendingRemoval.isEmpty else {
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

    func play(_ item: LibraryMediaItem) {
        guard !isShutDown,
              !rootIDsPendingRemoval.contains(
                MediaLibraryRoot.ID(
                    standardizedPath: item.rootURL.standardizedFileURL.path
                )
              ),
              items.contains(where: { $0.id == item.id }) else {
            return
        }

        let playbackItems = items
        guard !playbackItems.isEmpty else {
            return
        }

        queueItemsByID = Dictionary(
            uniqueKeysWithValues: playbackItems.map { ($0.id, $0) }
        )
        let itemIDs = playbackItems.map(\.id)
        queue = PlaybackQueue(
            items: itemIDs,
            startingAt: item.id,
            order: playbackOrder
        )
        currentItemID = queue?.currentItem
        publishQueueChange()
        unavailableItemIDs.remove(item.id)
        loadCurrentItem(attemptsRemaining: itemIDs.count)
    }

    @discardableResult
    func playNext() -> Bool {
        guard var queue else {
            return false
        }
        let queueCount = queue.count
        guard let nextID = nextAvailableItem(
            in: &queue,
            maximumAdvances: queueCount
        ) else {
            return false
        }
        self.queue = queue
        currentItemID = nextID
        publishQueueChange()
        loadCurrentItem(attemptsRemaining: queue.count)
        return true
    }

    func playPrevious() {
        guard var queue else {
            return
        }

        let queueCount = queue.count
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
            publishQueueChange()
            loadCurrentItem(attemptsRemaining: queueCount)
            return
        }
    }

    func setPlaybackOrder(_ order: PlaybackOrder) {
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
        guard sort.field != field else {
            return
        }
        sort.field = field
        items = sort.sorted(items)
        preferencesStore?.saveLibrarySort(sort)
    }

    func toggleSortDirection() {
        sort.direction.toggle()
        items = sort.sorted(items)
        preferencesStore?.saveLibrarySort(sort)
    }

    func setSortDirection(_ direction: MediaLibrarySortDirection) {
        guard sort.direction != direction else {
            return
        }
        sort.direction = direction
        items = sort.sorted(items)
        preferencesStore?.saveLibrarySort(sort)
    }

    func makeQueueSnapshot() ->
        PlaybackQueueSnapshot<LibraryMediaItem.ID>? {
        queue?.makeSnapshot()
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
        let availableItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        let canonicalSnapshot = remappedQueueSnapshot(
            snapshot,
            using: availableItemsByID
        )
        guard var restoredQueue = PlaybackQueue(
            snapshot: canonicalSnapshot
        ) else {
            return .permanentlyUnavailable
        }
        let missingItemIDs = Set(snapshot.items)
            .subtracting(availableItemsByID.keys)
        let requestedRootPaths = Set(
            activeSources.map { $0.id.standardizedPath }
        )
        let missingMediaPaths = Set(
            missingItemIDs.map(\.standardizedMediaPath)
        )
        let hasIncompleteRoot = missingMediaPaths.contains { mediaPath in
            incompleteRootPaths.contains {
                sourcePath($0, coversMediaPath: mediaPath)
            }
        }
        let hasUnavailableRequestedRoot = missingMediaPaths.contains {
            mediaPath in
            requestedRootPaths.contains {
                sourcePath($0, coversMediaPath: mediaPath)
            }
                && !roots.contains {
                    sourcePath(
                        $0.id.standardizedPath,
                        coversMediaPath: mediaPath
                    )
                }
        }
        let hasPossiblyUnavailableUnresolvedRoot =
            mediaSession.hasUnavailablePersistedSources
                && missingMediaPaths.contains { mediaPath in
                    !roots.contains {
                        sourcePath(
                            $0.id.standardizedPath,
                            coversMediaPath: mediaPath
                        )
                    }
                }
        if hasIncompleteRoot
            || hasUnavailableRequestedRoot
            || hasPossiblyUnavailableUnresolvedRoot {
            return .temporarilyUnavailable
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
        queue = restoredQueue
        currentItemID = restoredItemID
        publishQueueChange()
        unavailableItemIDs.formIntersection(availableItemsByID.keys)

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
        invalidatePendingImport()
        importNotice = nil
        playback.itemEndedHandler = nil
        playback.itemFailureHandler = nil

        let pendingScanTasks = cancelAllScanTasks()
        let pendingLoadTasks = cancelAllLoadTasks()

        for task in pendingScanTasks {
            await task.value
        }
        for task in pendingLoadTasks {
            await task.value
        }

        mediaSession.stop()
        activeSources = []
        latestPreparedSources = []
        preparedSourcesNeedRefresh = false
        supersededThumbnailRootPaths = []
        incompleteRootPaths = []
        queue = nil
        currentItemID = nil
        loadedItemID = nil
        queueItemsByID.removeAll()
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
                        mergeImportedCandidates(representedCandidates)
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
                publish(snapshot, for: sources)
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
        for requestedSources: [MediaSource]
    ) {
        let requestedSourcePaths = sourcePathSet(requestedSources)
        let scannedRoots = snapshot.roots.filter {
            requestedSourcePaths.contains($0.id.standardizedPath)
        }
        let scannedItems = snapshot.items.filter {
            requestedSourcePaths.contains(
                $0.rootURL.standardizedFileURL.path
            )
        }
        let scannedItemsByID = Dictionary(
            uniqueKeysWithValues: scannedItems.map { ($0.id, $0) }
        )

        mediaThumbnailProvider.allowThumbnails(
            forRootIDs: Set(scannedRoots.map(\.id))
        )
        roots = scannedRoots
        items = sort.sorted(scannedItems)
        incompleteRootPaths = snapshot.incompleteRootPaths
            .intersection(requestedSourcePaths)
        unavailableItemIDs.formIntersection(Set(items.map(\.id)))

        reconcileActiveQueue(using: scannedItemsByID)
        if requestedSourcePaths == sourcePathSet(latestPreparedSources) {
            preparedSourcesNeedRefresh = false
        }
        scanState = .ready
    }

    private func mergeImportedCandidates(
        _ candidates: [LibraryMediaItem]
    ) {
        var mergedItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        for candidate in candidates {
            mergedItemsByID[candidate.id] = candidate
            unavailableItemIDs.remove(candidate.id)
        }
        items = sort.sorted(Array(mergedItemsByID.values))
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
        let candidateItems = candidates ?? items
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: candidateItems.map { ($0.id, $0) }
        )
        var candidatesByCanonicalPath: [String: LibraryMediaItem]?
        var canonicalRootURLsByPath: [String: URL] = [:]
        func canonicalCandidates() -> [String: LibraryMediaItem] {
            if let candidatesByCanonicalPath {
                return candidatesByCanonicalPath
            }
            var indexedCandidates: [String: LibraryMediaItem] = [:]
            for item in candidateItems {
                let rootPath = item.rootURL.standardizedFileURL.path
                let canonicalRootURL: URL
                if let cachedRootURL = canonicalRootURLsByPath[rootPath] {
                    canonicalRootURL = cachedRootURL
                } else {
                    canonicalRootURL = canonicalComparisonURL(item.rootURL)
                    canonicalRootURLsByPath[rootPath] = canonicalRootURL
                }
                let canonicalItemURL = if item.relativePath.isEmpty {
                    canonicalRootURL
                } else {
                    canonicalRootURL.appendingPathComponent(
                        item.relativePath
                    )
                }
                indexedCandidates[
                    canonicalItemURL.standardizedFileURL.path
                ] = item
            }
            candidatesByCanonicalPath = indexedCandidates
            return indexedCandidates
        }
        for fileURL in fileURLs {
            if let item = candidatesByID[
                LibraryMediaItem.ID(mediaURL: fileURL)
            ] {
                return item
            }
            let comparisonPath = canonicalComparisonURL(fileURL).path
            if let item = canonicalCandidates()[comparisonPath] {
                return item
            }
        }
        return nil
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
        guard expandQueue, let queue else {
            return
        }
        let visibleItemIDs = items.map(\.id)
        guard Set(queue.items) != Set(visibleItemIDs) else {
            return
        }

        queueItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        self.queue = PlaybackQueue(
            items: visibleItemIDs,
            startingAt: item.id,
            order: playbackOrder
        )
        currentItemID = self.queue?.currentItem
        unavailableItemIDs.formIntersection(Set(visibleItemIDs))
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
        let visibleItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
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

        guard let queue else {
            return
        }
        guard let snapshot = queue.makeSnapshot() else {
            return
        }
        let remappedSnapshot = remappedQueueSnapshot(
            snapshot,
            using: availableItemsByID
        )
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
        unavailableItemIDs = Set(unavailableItemIDs.map {
            availableItemsByID[$0]?.id ?? $0
        })
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

    private func sourcePath(
        _ sourcePath: String,
        coversMediaPath mediaPath: String
    ) -> Bool {
        let sourceComponents = URL(
            fileURLWithPath: sourcePath
        ).standardizedFileURL.pathComponents
        let mediaComponents = URL(
            fileURLWithPath: mediaPath
        ).standardizedFileURL.pathComponents
        return mediaComponents.starts(with: sourceComponents)
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
        currentItemID = nil
        queueItemsByID.removeAll()
        if !preservingUnavailableItems {
            unavailableItemIDs.removeAll()
        }
        publishQueueChange()
    }

    private func publishQueueChange() {
        queueRevision &+= 1
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
        guard attemptsRemaining > 0,
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
                unavailableItemIDs.remove(item.id)
            case let .mediaFailure(failure):
                unavailableItemIDs.insert(item.id)
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
        attachToPlayerSurface: Bool
    ) async -> MediaLibraryQueueRestoreResult {
        var remainingAttempts = attemptsRemaining

        while remainingAttempts > 0 {
            guard !Task.isCancelled,
                  !isShutDown,
                  let currentItemID,
                  let item = queueItemsByID[currentItemID] else {
                return Task.isCancelled ? .cancelled : .temporarilyUnavailable
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
            guard !Task.isCancelled, !isShutDown else {
                return .cancelled
            }

            switch result {
            case .loaded:
                loadedItemID = item.id
                unavailableItemIDs.remove(item.id)
                return .restored
            case let .mediaFailure(failure):
                guard await isPermanentlyUnavailable(
                    item,
                    after: failure
                ) else {
                    return .temporarilyUnavailable
                }

                unavailableItemIDs.insert(item.id)
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

        stopPlaybackAndClearQueue()
        return .permanentlyUnavailable
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
        publishQueueChange()
        loadCurrentItem(
            attemptsRemaining: attemptsRemaining,
            autoplay: autoplay
        )
        return true
    }

    private func handleItemEnded() -> Bool {
        guard queue != nil, !isShutDown else {
            return false
        }
        return playNext()
    }

    private func handleItemFailure() -> Bool {
        guard !isShutDown,
              let failedItemID = currentItemID,
              var queue else {
            return false
        }

        unavailableItemIDs.insert(failedItemID)
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
        publishQueueChange()
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
