import Combine
import Foundation

enum MediaLibraryScanState: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case failed
}

@MainActor
final class MediaLibraryCoordinator: ObservableObject {
    @Published private(set) var scanState: MediaLibraryScanState = .idle
    @Published private(set) var roots: [MediaLibraryRoot] = []
    @Published private(set) var items: [LibraryMediaItem] = []
    @Published private(set) var playbackOrder: PlaybackOrder
    @Published private(set) var sort: MediaLibrarySort
    @Published private(set) var currentItemID: LibraryMediaItem.ID?
    @Published private(set) var unavailableItemIDs: Set<LibraryMediaItem.ID> = []

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
    private let preferencesStore: (any AppPreferencesStoring)?

    private var rootURLs: [URL] = []
    private var queue: PlaybackQueue<LibraryMediaItem.ID>?
    private var queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
    private var scanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var hasStarted = false
    private var isShutDown = false

    init(
        playback: PlaybackCoordinator,
        folderSelector: any MediaFolderSelecting,
        mediaSession: any MediaAccessSession,
        scanner: any MediaLibraryScanning,
        playbackOrder: PlaybackOrder,
        sort: MediaLibrarySort = MediaLibrarySort(),
        preferencesStore: (any AppPreferencesStoring)? = nil
    ) {
        self.playback = playback
        self.folderSelector = folderSelector
        self.mediaSession = mediaSession
        self.scanner = scanner
        self.playbackOrder = playbackOrder
        self.sort = sort
        self.preferencesStore = preferencesStore

        playback.itemEndedHandler = { [weak self] in
            self?.handleItemEnded() ?? false
        }
        playback.itemFailureHandler = { [weak self] _ in
            self?.handleItemFailure() ?? false
        }
    }

    func start() {
        guard !hasStarted, !isShutDown else {
            return
        }
        hasStarted = true

        let restoredURLs = mediaSession.restoreFolders()
        guard !restoredURLs.isEmpty else {
            scanState = .idle
            return
        }
        refresh(using: restoredURLs)
    }

    func addFolders() {
        guard !isShutDown else {
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

    func removeRoot(_ root: MediaLibraryRoot) {
        guard !isShutDown,
              roots.contains(where: { $0.id == root.id }) else {
            return
        }

        let remainingRootURLs = mediaSession.removeFolder(root.url)
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

        removeItemsFromActiveQueue(removedItemIDs)

        if remainingRootURLs.isEmpty {
            invalidateScan()
            rootURLs = []
            scanState = .idle
            if queue == nil {
                stopPlaybackAndClearQueue()
            }
        } else {
            refresh(using: remainingRootURLs)
        }
    }

    func refresh() {
        guard !rootURLs.isEmpty else {
            return
        }
        refresh(using: rootURLs)
    }

    func play(_ item: LibraryMediaItem) {
        guard !isShutDown else {
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

    func shutdown() async {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        scanGeneration &+= 1
        loadGeneration &+= 1
        playback.itemEndedHandler = nil
        playback.itemFailureHandler = nil

        let pendingScanTask = scanTask
        let pendingLoadTask = loadTask
        pendingScanTask?.cancel()
        pendingLoadTask?.cancel()
        scanTask = nil
        loadTask = nil

        if let pendingScanTask {
            await pendingScanTask.value
        }
        if let pendingLoadTask {
            await pendingLoadTask.value
        }

        mediaSession.stop()
        rootURLs = []
        queue = nil
        queueItemsByID.removeAll()
    }

    private func refresh(using rootURLs: [URL]) {
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask?.cancel()
        self.rootURLs = rootURLs
        scanState = .scanning

        scanTask = Task { [weak self, scanner] in
            do {
                let snapshot = try await scanner.scan(rootURLs: rootURLs)
                try Task.checkCancellation()
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                roots = snapshot.roots
                items = sort.sorted(snapshot.items)
                unavailableItemIDs.formIntersection(
                    Set(items.map(\.id))
                )
                scanState = .ready
                scanTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == scanGeneration,
                      !isShutDown else {
                    return
                }
                scanState = .failed
                scanTask = nil
            }
        }
    }

    private func removeItemsFromActiveQueue(
        _ removedItemIDs: Set<LibraryMediaItem.ID>
    ) {
        guard !removedItemIDs.isEmpty, var queue else {
            return
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
            stopPlaybackAndClearQueue()
            return
        }

        self.queue = queue
        guard removedCurrentItem else {
            return
        }

        invalidateLoad()
        currentItemID = nextItemID
        loadCurrentItem(attemptsRemaining: queue.count)
    }

    private func stopPlaybackAndClearQueue() {
        invalidateLoad()
        playback.stop()
        queue = nil
        currentItemID = nil
        queueItemsByID.removeAll()
        unavailableItemIDs.removeAll()
    }

    private func invalidateScan() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
    }

    private func invalidateLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func loadCurrentItem(attemptsRemaining: Int) {
        guard attemptsRemaining > 0,
              let currentItemID,
              let item = queueItemsByID[currentItemID] else {
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()

        let source = ResolvedMediaSource(
            url: item.url,
            displayName: item.displayName
        )
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await playback.load(source)
            guard generation == loadGeneration, !isShutDown else {
                return
            }
            loadTask = nil

            switch result {
            case .loaded:
                unavailableItemIDs.remove(item.id)
            case let .mediaFailure(failure):
                unavailableItemIDs.insert(item.id)
                let didAdvance = advanceAfterFailedLoad(
                    failedItemID: item.id,
                    attemptsRemaining: attemptsRemaining - 1
                )
                if !didAdvance {
                    playback.finishQueue(with: failure)
                }
            case .globalFailure, .cancelled:
                break
            }
        }
    }

    @discardableResult
    private func advanceAfterFailedLoad(
        failedItemID: LibraryMediaItem.ID,
        attemptsRemaining: Int
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
        loadCurrentItem(attemptsRemaining: attemptsRemaining)
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
            return false
        }

        self.queue = queue
        currentItemID = nextID
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
