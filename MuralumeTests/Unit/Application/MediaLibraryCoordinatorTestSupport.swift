import CoreGraphics
import Foundation
@testable import Muralume

@MainActor
func makeFixture(
    selectedURLs: [URL],
    snapshot: MediaLibrarySnapshot,
    playbackOrder: PlaybackOrder = .ordered,
    sort: MediaLibrarySort = MediaLibrarySort(),
    preferencesStore: (any AppPreferencesStoring)? = nil,
    mediaThumbnailProvider: TestMediaThumbnailProvider =
        TestMediaThumbnailProvider(),
    reshuffleRestoredQueue: @escaping RestoredPlaybackQueueShuffler = {
        $0.reshufflePendingItems()
    }
) -> Fixture {
    let engine = TestPlaybackEngine()
    let playback = PlaybackCoordinator(engine: engine)
    let selector = TestMediaFolderSelector(selectedURLs: selectedURLs)
    let session = TestMediaAccessSession()
    let scanner = TestMediaLibraryScanner(snapshot: snapshot)
    let coordinator = MediaLibraryCoordinator(
        playback: playback,
        folderSelector: selector,
        mediaSession: session,
        scanner: scanner,
        mediaThumbnailProvider: mediaThumbnailProvider,
        playbackOrder: playbackOrder,
        sort: sort,
        preferencesStore: preferencesStore,
        reshuffleRestoredQueue: reshuffleRestoredQueue
    )
    return Fixture(
        coordinator: coordinator,
        playback: playback,
        engine: engine,
        session: session,
        scanner: scanner,
        mediaThumbnailProvider: mediaThumbnailProvider
    )
}

func makeItem(
    rootURL: URL,
    name: String,
    path: String,
    fileSize: Int64 = 0
) -> LibraryMediaItem {
    LibraryMediaItem(
        rootURL: rootURL,
        rootName: rootURL.lastPathComponent,
        url: rootURL.appendingPathComponent(path),
        displayName: name,
        relativePath: path,
        relativeDirectory: "",
        creationDate: nil,
        fileSize: fileSize
    )
}

@MainActor
func waitForScan(_ coordinator: MediaLibraryCoordinator) async {
    while coordinator.scanState == .scanning {
        await Task.yield()
    }
}

@MainActor
func waitForLoads(
    _ engine: TestPlaybackEngine,
    count: Int
) async {
    while engine.loadedSources.count < count {
        await Task.yield()
    }
}

@MainActor
func waitForReady(_ playback: PlaybackCoordinator) async {
    while playback.readiness != .ready {
        await Task.yield()
    }
}

@MainActor
func waitForFailure(_ playback: PlaybackCoordinator) async {
    while true {
        if case .failed = playback.readiness {
            return
        }
        await Task.yield()
    }
}

@MainActor
struct Fixture {
    let coordinator: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    let engine: TestPlaybackEngine
    let session: TestMediaAccessSession
    let scanner: TestMediaLibraryScanner
    let mediaThumbnailProvider: TestMediaThumbnailProvider
}

@MainActor
final class TestMediaFolderSelector: MediaFolderSelecting {
    let selectedURLs: [URL]

    init(selectedURLs: [URL]) {
        self.selectedURLs = selectedURLs
    }

    func selectFolders() -> [URL] {
        selectedURLs
    }
}

@MainActor
final class TestMediaAccessSession: MediaAccessSession {
    private(set) var addedURLs: [URL] = []
    private(set) var preparedRemovalURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    var restoredURLs: [URL] = []
    var hasUnavailablePersistedFolders = false

    func restoreFolders() -> [URL] {
        restoredURLs
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        addedURLs.append(contentsOf: urls)
        return addedURLs
    }

    func prepareToRemoveFolder(_ url: URL) {
        preparedRemovalURLs.append(url)
    }

    func removeFolder(_ url: URL) -> [URL] {
        removedURLs.append(url)
        addedURLs.removeAll {
            $0.standardizedFileURL == url.standardizedFileURL
        }
        restoredURLs.removeAll {
            $0.standardizedFileURL == url.standardizedFileURL
        }
        return addedURLs.isEmpty ? restoredURLs : addedURLs
    }

    func stop() {}
}

final class TestMediaLibraryScanner: MediaLibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: MediaLibrarySnapshot
    private var storedScannedRootURLs: [[URL]] = []
    private var shouldBlockNextScan = false
    private var blockedScanDidBegin = false
    private var blockedScanContinuation: CheckedContinuation<Void, Never>?
    var availabilityByItemID:
        [LibraryMediaItem.ID: MediaLibraryItemAvailability] = [:]

    var scannedRootURLs: [[URL]] {
        lock.withLock {
            storedScannedRootURLs
        }
    }

    var didBeginBlockedScan: Bool {
        lock.withLock {
            blockedScanDidBegin
        }
    }

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        let shouldBlock = lock.withLock {
            storedScannedRootURLs.append(rootURLs)
            guard shouldBlockNextScan else {
                return false
            }
            shouldBlockNextScan = false
            blockedScanDidBegin = true
            return true
        }
        if shouldBlock {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    blockedScanContinuation = continuation
                }
            }
            try Task.checkCancellation()
        }
        return snapshot
    }

    func blockNextScan() {
        lock.withLock {
            shouldBlockNextScan = true
            blockedScanDidBegin = false
        }
    }

    func finishBlockedScan() {
        let continuation = lock.withLock {
            let continuation = blockedScanContinuation
            blockedScanContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        availabilityByItemID[item.id] ?? .temporarilyUnavailable
    }
}

@MainActor
final class TestMediaThumbnailProvider: MediaThumbnailProviding {
    private(set) var allowedRootIDSets: [Set<MediaLibraryRoot.ID>] = []
    private(set) var invalidatedRootIDs: [MediaLibraryRoot.ID] = []
    private(set) var purgeMemoryCacheCount = 0
    private(set) var shutdownCount = 0
    var shouldBlockInvalidation = false
    private var invalidationContinuations:
        [MediaLibraryRoot.ID: CheckedContinuation<Void, Never>] = [:]

    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        nil
    }

    func purgeMemoryCache() {
        purgeMemoryCacheCount += 1
    }

    func allowThumbnails(forRootIDs rootIDs: Set<MediaLibraryRoot.ID>) {
        allowedRootIDSets.append(rootIDs)
    }

    func invalidateThumbnails(
        forRootID rootID: MediaLibraryRoot.ID
    ) async {
        invalidatedRootIDs.append(rootID)
        guard shouldBlockInvalidation else {
            return
        }
        await withCheckedContinuation { continuation in
            invalidationContinuations[rootID] = continuation
        }
    }

    func finishInvalidation(for rootID: MediaLibraryRoot.ID) {
        invalidationContinuations.removeValue(forKey: rootID)?.resume()
    }

    func shutdown() async {
        shutdownCount += 1
        let continuations = invalidationContinuations.values
        invalidationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

struct TestSeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
