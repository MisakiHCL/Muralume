import Foundation
@testable import Muralume

@MainActor
func makeFixture(
    selectedURLs: [URL],
    snapshot: MediaLibrarySnapshot,
    playbackOrder: PlaybackOrder = .ordered,
    sort: MediaLibrarySort = MediaLibrarySort(),
    preferencesStore: (any AppPreferencesStoring)? = nil,
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
        scanner: scanner
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
    var restoredURLs: [URL] = []
    var hasUnavailablePersistedFolders = false

    func restoreFolders() -> [URL] {
        restoredURLs
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        addedURLs.append(contentsOf: urls)
        return addedURLs
    }

    func removeFolder(_ url: URL) -> [URL] {
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
    var availabilityByItemID:
        [LibraryMediaItem.ID: MediaLibraryItemAvailability] = [:]

    var scannedRootURLs: [[URL]] {
        lock.withLock {
            storedScannedRootURLs
        }
    }

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        lock.withLock {
            storedScannedRootURLs.append(rootURLs)
        }
        return snapshot
    }

    func availability(
        of item: LibraryMediaItem
    ) async -> MediaLibraryItemAvailability {
        availabilityByItemID[item.id] ?? .temporarilyUnavailable
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
