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

    @Published private(set) var scanState: MediaLibraryScanState = .idle
    @Published private(set) var roots: [MediaLibraryRoot] = []
    @Published private(set) var items: [LibraryMediaItem] = []
    @Published private(set) var playbackOrder: PlaybackOrder
    @Published private(set) var sort: MediaLibrarySort
    @Published private(set) var currentItemID: LibraryMediaItem.ID?
    @Published private(set) var unavailableItemIDs: Set<LibraryMediaItem.ID> = []
    @Published private(set) var queueRevision: UInt64 = 0

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
    private let folderSelector: any MediaFolderSelecting
    private let mediaSession: any MediaAccessSession
    private let scanner: any MediaLibraryScanning
    private let mediaThumbnailProvider: any MediaThumbnailProviding
    private let preferencesStore: (any AppPreferencesStoring)?
    private let reshuffleRestoredQueue: RestoredPlaybackQueueShuffler

    private var rootURLs: [URL] = []
    private var incompleteRootPaths: Set<String> = []
    private var queue: PlaybackQueue<LibraryMediaItem.ID>?
    private var queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var currentScanTaskID: UUID?
    private var loadTasks: [UUID: LoadTaskRecord] = [:]
    private var currentLoadTaskID: UUID?
    private var loadedItemID: LibraryMediaItem.ID?
    private var rootIDsPendingRemoval: Set<MediaLibraryRoot.ID> = []
    private var scanGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var hasStarted = false
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        folderSelector: any MediaFolderSelecting,
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
        self.folderSelector = folderSelector
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

        let restoredURLs = mediaSession.restoreFolders()
        guard !restoredURLs.isEmpty else {
            scanState = .idle
            return .noRestorableRoots(
                hasTemporarilyUnavailableRoots:
                    mediaSession.hasUnavailablePersistedFolders
            )
        }
        refresh(using: restoredURLs)
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

    func addFolders() {
        guard !isShutDown, rootIDsPendingRemoval.isEmpty else {
            return
        }
        let selectedURLs = folderSelector.selectFolders()
        guard !selectedURLs.isEmpty else {
            return
        }

        let activeURLs = mediaSession.addFolders(selectedURLs)
        guard !activeURLs.isEmpty else {
            scanState = .failed
            return
        }
        refresh(using: activeURLs)
    }

    func removeRoot(_ root: MediaLibraryRoot) async {
        guard !isShutDown,
              roots.contains(where: { $0.id == root.id }),
              rootIDsPendingRemoval.insert(root.id).inserted else {
            return
        }
        defer {
            rootIDsPendingRemoval.remove(root.id)
        }

        // Persist the user's decision first, but keep the active security scope
        // until every scanner, thumbnail request, and playback load has drained.
        mediaSession.prepareToRemoveFolder(root.url)
        let removedRootPath = root.id.standardizedPath
        let removedItemIDs = Set(
            queueItemsByID.keys.filter {
                $0.rootPath == removedRootPath
            }
        ).union(
            items.lazy
                .filter { $0.id.rootPath == removedRootPath }
                .map(\.id)
        )

        let scanTasksToDrain = cancelAllScanTasks()
        let playbackTouchesRemovedRoot =
            loadedItemID?.rootPath == removedRootPath
            || loadTasks.values.contains {
                $0.itemID.rootPath == removedRootPath
            }
            || (
                currentItemID?.rootPath == removedRootPath
                    && playback.readiness != .empty
            )
        let shouldAutoplayAfterDrain = playback.isPlaybackRequested
            || currentLoadTaskRecord?.autoplay == true
        let loadTasksToDrain: [Task<Void, Never>]
        if playbackTouchesRemovedRoot {
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
            $0.id.rootPath == removedRootPath
        }
        unavailableItemIDs.subtract(removedItemIDs)
        for itemID in removedItemIDs {
            queueItemsByID[itemID] = nil
        }
        rootURLs.removeAll {
            $0.standardizedFileURL.path == removedRootPath
        }

        let removedCurrentItem = removeItemsFromActiveQueue(removedItemIDs)
        let expectedReloadItemID = currentItemID
        let reloadGeneration = loadGeneration

        let thumbnailDrainTask = Task { @MainActor [mediaThumbnailProvider] in
            await mediaThumbnailProvider.invalidateThumbnails(
                forRootID: root.id
            )
        }
        for task in scanTasksToDrain {
            await task.value
        }
        for task in loadTasksToDrain {
            await task.value
        }
        await thumbnailDrainTask.value

        let activeRootURLs = mediaSession.removeFolder(root.url)
        let pendingRootPaths = Set(
            rootIDsPendingRemoval.map(\.standardizedPath)
        )
        let remainingRootURLs = activeRootURLs.filter {
            !pendingRootPaths.contains($0.standardizedFileURL.path)
        }

        guard !isShutDown else {
            return
        }

        rootURLs = remainingRootURLs
        let shouldReloadCurrentItem =
            (playbackTouchesRemovedRoot || removedCurrentItem)
            && loadGeneration == reloadGeneration
            && currentItemID == expectedReloadItemID
            && expectedReloadItemID != nil
        if shouldReloadCurrentItem {
            loadCurrentItem(
                attemptsRemaining: queue?.count ?? 0,
                autoplay: shouldAutoplayAfterDrain
            )
        }

        if remainingRootURLs.isEmpty {
            incompleteRootPaths = []
            scanState = .idle
            if queue == nil {
                stopPlaybackAndClearQueue()
            }
        } else {
            refresh(using: remainingRootURLs)
        }
    }

    func refresh() {
        guard !rootURLs.isEmpty, rootIDsPendingRemoval.isEmpty else {
            return
        }
        refresh(using: rootURLs)
    }

    func play(_ item: LibraryMediaItem) {
        guard !isShutDown,
              !rootIDsPendingRemoval.contains(
                MediaLibraryRoot.ID(standardizedPath: item.id.rootPath)
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
        guard var restoredQueue = PlaybackQueue(snapshot: snapshot) else {
            return .permanentlyUnavailable
        }

        let availableItemsByID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )
        let missingItemIDs = Set(snapshot.items)
            .subtracting(availableItemsByID.keys)
        let successfulRootPaths = Set(
            roots.map(\.id.standardizedPath)
        )
        let requestedRootPaths = Set(
            rootURLs.map { $0.standardizedFileURL.path }
        )
        let missingRootPaths = Set(missingItemIDs.map(\.rootPath))
        let hasIncompleteRoot = !missingRootPaths
            .isDisjoint(with: incompleteRootPaths)
        let hasUnavailableRequestedRoot = missingRootPaths.contains {
            requestedRootPaths.contains($0)
                && !successfulRootPaths.contains($0)
        }
        let hasPossiblyUnavailableUnresolvedRoot =
            mediaSession.hasUnavailablePersistedFolders
                && missingRootPaths.contains {
                    !successfulRootPaths.contains($0)
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
        rootURLs = []
        incompleteRootPaths = []
        queue = nil
        currentItemID = nil
        loadedItemID = nil
        queueItemsByID.removeAll()
    }

    private func refresh(using rootURLs: [URL]) {
        scanGeneration &+= 1
        let generation = scanGeneration
        cancelCurrentScanTask()
        self.rootURLs = rootURLs
        scanState = .scanning

        let taskID = UUID()
        let task = Task { [weak self, scanner] in
            defer {
                self?.finishScanTask(taskID)
            }
            do {
                let snapshot = try await scanner.scan(rootURLs: rootURLs)
                try Task.checkCancellation()
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                let requestedRootPaths = Set(
                    rootURLs.map { $0.standardizedFileURL.path }
                )
                let scannedRoots = snapshot.roots.filter {
                    requestedRootPaths.contains($0.id.standardizedPath)
                }
                let scannedItems = snapshot.items.filter {
                    requestedRootPaths.contains($0.id.rootPath)
                }
                mediaThumbnailProvider.allowThumbnails(
                    forRootIDs: Set(scannedRoots.map(\.id))
                )
                roots = scannedRoots
                items = sort.sorted(scannedItems)
                incompleteRootPaths = snapshot.incompleteRootPaths
                    .intersection(requestedRootPaths)
                unavailableItemIDs.formIntersection(
                    Set(items.map(\.id))
                )
                scanState = .ready
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
    }

    private func cancelAllScanTasks() -> [Task<Void, Never>] {
        scanGeneration &+= 1
        let tasks = Array(scanTasks.values)
        tasks.forEach { $0.cancel() }
        currentScanTaskID = nil
        return tasks
    }

    private func finishScanTask(_ taskID: UUID) {
        scanTasks[taskID] = nil
        if currentScanTaskID == taskID {
            currentScanTaskID = nil
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
