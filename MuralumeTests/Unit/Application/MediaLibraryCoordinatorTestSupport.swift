import CoreGraphics
import Foundation
@testable import Muralume

@MainActor
func makeFixture(
    selectedURLs: [URL],
    subsequentSelectedURLs: [[URL]] = [],
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
    let selector = TestMediaSourceSelector(
        selections: [selectedURLs] + subsequentSelectedURLs
    )
    let session = TestMediaAccessSession()
    let scanner = TestMediaLibraryScanner(snapshot: snapshot)
    let coordinator = MediaLibraryCoordinator(
        playback: playback,
        sourceSelector: selector,
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
        sourceSelector: selector,
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

func makeFileItem(url: URL, name: String? = nil) -> LibraryMediaItem {
    LibraryMediaItem(
        rootURL: url,
        rootName: url.lastPathComponent,
        kind: .file,
        url: url,
        displayName: name
            ?? url.deletingPathExtension().lastPathComponent,
        relativePath: "",
        relativeDirectory: "",
        creationDate: nil,
        fileSize: 0
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
    let sourceSelector: TestMediaSourceSelector
    let session: TestMediaAccessSession
    let scanner: TestMediaLibraryScanner
    let mediaThumbnailProvider: TestMediaThumbnailProvider
}

@MainActor
final class TestMediaSourceSelector: MediaSourceSelecting {
    private var selections: [[URL]]
    private(set) var intents: [MediaSourceSelectionIntent] = []

    init(selections: [[URL]]) {
        self.selections = selections
    }

    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL] {
        intents.append(intent)
        guard !selections.isEmpty else {
            return []
        }
        return selections.removeFirst()
    }
}

@MainActor
final class TestMediaAccessSession: MediaAccessSession {
    private(set) var addedURLs: [URL] = []
    private(set) var preparedRemovalURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    var restoredURLs: [URL] = []
    var hasUnavailablePersistedSources = false
    var treatsFilesInsideActiveFoldersAsCovered = false
    var replacesFilesCoveredByAddedFolder = false

    func retryUnavailableSources() -> [MediaSource] {
        activeURLs.map(makeSource)
    }

    func restoreSources() -> [MediaSource] {
        activeURLs.map(makeSource)
    }

    func addSources(_ urls: [URL]) -> MediaAccessUpdate {
        var didChangeSources = false
        for url in urls {
            if replacesFilesCoveredByAddedFolder,
               !isSupportedVideo(url) {
                let removedAddedCount = addedURLs.count
                let removedRestoredCount = restoredURLs.count
                addedURLs.removeAll {
                    isSupportedVideo($0)
                        && $0.standardizedFileURL.pathComponents.starts(
                            with: url.standardizedFileURL.pathComponents
                        )
                }
                restoredURLs.removeAll {
                    isSupportedVideo($0)
                        && $0.standardizedFileURL.pathComponents.starts(
                            with: url.standardizedFileURL.pathComponents
                        )
                }
                didChangeSources = didChangeSources
                    || removedAddedCount != addedURLs.count
                    || removedRestoredCount != restoredURLs.count
            }
            guard !isAlreadyActiveOrCovered(url) else {
                continue
            }
            addedURLs.append(url)
            didChangeSources = true
        }
        return MediaAccessUpdate(
            activeSources: activeURLs.map(makeSource),
            requestedFileURLs: urls.filter(isSupportedVideo),
            acceptedRequestCount: urls.count,
            rejectedRequestCount: 0,
            didChangeSources: didChangeSources
        )
    }

    func prepareToRemoveSource(_ source: MediaSource) {
        preparedRemovalURLs.append(source.url)
    }

    func removeSource(_ source: MediaSource) -> [MediaSource] {
        let url = source.url
        removedURLs.append(url)
        addedURLs.removeAll {
            $0.standardizedFileURL == url.standardizedFileURL
        }
        restoredURLs.removeAll {
            $0.standardizedFileURL == url.standardizedFileURL
        }
        return activeURLs.map(makeSource)
    }

    func stop() {}

    private func makeSource(_ url: URL) -> MediaSource {
        MediaSource(
            url: url,
            kind: isSupportedVideo(url) ? .file : .folder
        )
    }

    private func isSupportedVideo(_ url: URL) -> Bool {
        MediaLibraryFilePolicy.supportedVideoExtensions.contains(
            url.pathExtension.lowercased()
        )
    }

    private var activeURLs: [URL] {
        var knownPaths: Set<String> = []
        return (restoredURLs + addedURLs).filter {
            knownPaths.insert($0.standardizedFileURL.path).inserted
        }
    }

    private func isAlreadyActiveOrCovered(_ url: URL) -> Bool {
        let standardizedURL = comparisonURL(url)
        if activeURLs.contains(where: {
            comparisonURL($0).path == standardizedURL.path
        }) {
            return true
        }
        guard treatsFilesInsideActiveFoldersAsCovered,
              isSupportedVideo(standardizedURL) else {
            return false
        }
        return activeURLs.contains { activeURL in
            guard !isSupportedVideo(activeURL) else {
                return false
            }
            return standardizedURL.pathComponents.starts(
                with: comparisonURL(activeURL).pathComponents
            )
        }
    }

    private func comparisonURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

final class TestMediaLibraryScanner: MediaLibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: MediaLibrarySnapshot
    private var queuedSnapshots: [MediaLibrarySnapshot] = []
    private var storedScannedRootURLs: [[URL]] = []
    private var storedScannedSources: [[MediaSource]] = []
    private var shouldBlockNextScan = false
    private var blockedScanSourcePaths: Set<String>?
    private var blockedScanDidBegin = false
    private var blockedScanContinuation: CheckedContinuation<Void, Never>?
    var availabilityByItemID:
        [LibraryMediaItem.ID: MediaLibraryItemAvailability] = [:]

    var scannedRootURLs: [[URL]] {
        lock.withLock {
            storedScannedRootURLs
        }
    }

    var scannedSources: [[MediaSource]] {
        lock.withLock {
            storedScannedSources
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

    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot {
        lock.withLock {
            storedScannedSources.append(sources)
        }
        return try await scan(rootURLs: sources.map(\.url))
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        let shouldBlock = lock.withLock {
            storedScannedRootURLs.append(rootURLs)
            guard shouldBlockNextScan else {
                return false
            }
            if let blockedScanSourcePaths,
               blockedScanSourcePaths != Set(
                   rootURLs.map { $0.standardizedFileURL.path }
               ) {
                return false
            }
            shouldBlockNextScan = false
            blockedScanSourcePaths = nil
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
        return lock.withLock {
            guard !queuedSnapshots.isEmpty else {
                return snapshot
            }
            return queuedSnapshots.removeFirst()
        }
    }

    func enqueueSnapshot(_ snapshot: MediaLibrarySnapshot) {
        lock.withLock {
            queuedSnapshots.append(snapshot)
        }
    }

    func blockNextScan(matching rootURLs: [URL]? = nil) {
        lock.withLock {
            shouldBlockNextScan = true
            blockedScanSourcePaths = rootURLs.map { urls in
                Set(urls.map { $0.standardizedFileURL.path })
            }
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
