import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryCoordinatorTests: XCTestCase {
    func testInjectedPreferencesDriveInitialOrderAndScanSortWithoutWrites() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let small = makeItem(
            rootURL: rootURL,
            name: "Small",
            path: "Small.mov",
            fileSize: 1
        )
        let large = makeItem(
            rootURL: rootURL,
            name: "Large",
            path: "Large.mov",
            fileSize: 2
        )
        let preferencesStore = TestAppPreferencesStore()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [small, large]
            ),
            playbackOrder: .shuffled,
            sort: MediaLibrarySort(
                field: .fileSize,
                direction: .descending
            ),
            preferencesStore: preferencesStore
        )

        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.playbackOrder, .shuffled)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Large", "Small"]
        )
        XCTAssertTrue(preferencesStore.savedPlaybackOrders.isEmpty)
        XCTAssertTrue(preferencesStore.savedLibrarySorts.isEmpty)
    }

    func testOrderAndSortPersistOnlyAfterRealChanges() {
        let preferencesStore = TestAppPreferencesStore()
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(roots: [], items: []),
            preferencesStore: preferencesStore
        )

        fixture.coordinator.setPlaybackOrder(.ordered)
        fixture.coordinator.setPlaybackOrder(.shuffled)
        fixture.coordinator.setPlaybackOrder(.shuffled)
        fixture.coordinator.setSortField(.name)
        fixture.coordinator.setSortDirection(.ascending)
        fixture.coordinator.setSortField(.fileSize)
        fixture.coordinator.toggleSortDirection()

        XCTAssertEqual(
            preferencesStore.savedPlaybackOrders,
            [.shuffled]
        )
        XCTAssertEqual(
            preferencesStore.savedLibrarySorts,
            [
                MediaLibrarySort(
                    field: .fileSize,
                    direction: .ascending
                ),
                MediaLibrarySort(
                    field: .fileSize,
                    direction: .descending
                )
            ]
        )
    }

    func testAddingFoldersScansAndPublishesSortedPlaylist() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let itemB = makeItem(rootURL: rootURL, name: "Clip 10", path: "B.mov")
        let itemA = makeItem(rootURL: rootURL, name: "Clip 2", path: "A.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [itemB, itemA]
            )
        )

        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.session.addedURLs, [rootURL])
        XCTAssertEqual(fixture.scanner.scannedRootURLs, [[rootURL]])
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["Clip 2", "Clip 10"]
        )
        XCTAssertEqual(fixture.coordinator.scanState, .ready)
    }

    func testRemovingLastRootReturnsLibraryToEmptyIdleState() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let item = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Library"
                    )
                ],
                items: [item]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(item)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        guard let root = fixture.coordinator.roots.first else {
            return XCTFail("Expected the selected root to be available.")
        }
        fixture.coordinator.removeRoot(root)

        XCTAssertTrue(fixture.coordinator.roots.isEmpty)
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        XCTAssertEqual(fixture.coordinator.scanState, .idle)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertEqual(fixture.playback.readiness, .empty)
    }

    func testPlayingAnItemCreatesStableQueueAndNavigates() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 2)
        fixture.coordinator.playPrevious()
        await waitForLoads(fixture.engine, count: 3)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["First", "Second", "First"]
        )
        XCTAssertEqual(fixture.coordinator.currentItem?.id, first.id)
        XCTAssertEqual(fixture.coordinator.currentPosition, 1)
    }

    func testClickingVisibleItemRebuildsQueueFromCurrentSortOrder() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "A",
            path: "A.mov",
            fileSize: 3
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "B",
            path: "B.mov",
            fileSize: 2
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "C",
            path: "C.mov",
            fileSize: 1
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second, third]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.coordinator.setSortField(.fileSize)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["C", "B", "A"]
        )
        fixture.coordinator.setSortDirection(.descending)
        XCTAssertEqual(
            fixture.coordinator.items.map(\.displayName),
            ["A", "B", "C"]
        )
        fixture.coordinator.setSortDirection(.ascending)
        fixture.coordinator.play(third)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 3)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["A", "C", "B"]
        )
    }

    func testPlaybackCompletionAutomaticallyAdvancesTheQueue() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)

        fixture.engine.emitItemEnded()
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(fixture.engine.loadedSources.last?.displayName, "Second")
        XCTAssertEqual(fixture.coordinator.currentItem?.id, second.id)
    }

    func testTimelineSeekToEndAdvancesQueueOnlyAfterRelease() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.playback.beginTimelineSeek()
        fixture.playback.seek(to: 120)
        fixture.engine.emitItemEnded()

        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.coordinator.currentItem?.id, first.id)

        fixture.playback.endTimelineSeek()
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(fixture.engine.loadedSources.last?.displayName, "Second")
        XCTAssertEqual(fixture.coordinator.currentItem?.id, second.id)
    }

    func testFailedItemIsSkippedWithoutLoopingForever() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.engine.loadErrorsByURL[broken.url] = .cannotOpen
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 2)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid"]
        )
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.contains(broken.id))
        XCTAssertEqual(fixture.coordinator.currentItem?.id, valid.id)
    }

    func testRuntimeFailureMarksItemUnavailableAndAdvances() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        fixture.engine.emitFailure(.cannotOpen)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid"]
        )
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.contains(broken.id))
        XCTAssertEqual(fixture.coordinator.currentItem?.id, valid.id)
        XCTAssertEqual(fixture.playback.readiness, .ready)
    }

    func testKnownUnavailableItemIsSkippedOnLaterRounds() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let broken = makeItem(rootURL: rootURL, name: "Broken", path: "Broken.mov")
        let valid = makeItem(rootURL: rootURL, name: "Valid", path: "Valid.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [broken, valid]
            )
        )
        fixture.engine.loadErrorsByURL[broken.url] = .cannotOpen
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(broken)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        fixture.coordinator.playNext()
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["Broken", "Valid", "Valid"]
        )
    }

    func testExhaustedQueueFinishesWithFailure() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.engine.loadErrorsByURL[first.url] = .cannotOpen
        fixture.engine.loadErrorsByURL[second.url] = .cannotOpen
        var reportedFailure: PlaybackFailure?
        fixture.playback.playbackFailureHandler = {
            reportedFailure = $0
        }
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 2)
        await waitForFailure(fixture.playback)

        XCTAssertEqual(reportedFailure, .cannotOpen)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertEqual(
            fixture.coordinator.unavailableItemIDs,
            [first.id, second.id]
        )
    }

    func testGlobalLoadFailureDoesNotMarkMediaUnavailableOrSkipQueue() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Library")
        let first = makeItem(rootURL: rootURL, name: "First", path: "First.mov")
        let second = makeItem(rootURL: rootURL, name: "Second", path: "Second.mov")
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: [first, second]
            )
        )
        fixture.engine.loadErrorsByURL[first.url] = .surfaceTimeout
        var reportedFailure: PlaybackFailure?
        fixture.playback.playbackFailureHandler = {
            reportedFailure = $0
        }
        fixture.coordinator.addFolders()
        await waitForScan(fixture.coordinator)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForFailure(fixture.playback)

        XCTAssertEqual(reportedFailure, .surfaceTimeout)
        XCTAssertTrue(fixture.coordinator.unavailableItemIDs.isEmpty)
        XCTAssertEqual(
            fixture.engine.loadedSources.map(\.displayName),
            ["First"]
        )
    }

    private func makeFixture(
        selectedURLs: [URL],
        snapshot: MediaLibrarySnapshot,
        playbackOrder: PlaybackOrder = .ordered,
        sort: MediaLibrarySort = MediaLibrarySort(),
        preferencesStore: (any AppPreferencesStoring)? = nil
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
            preferencesStore: preferencesStore
        )
        return Fixture(
            coordinator: coordinator,
            playback: playback,
            engine: engine,
            session: session,
            scanner: scanner
        )
    }

    private func makeItem(
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

    private func waitForScan(_ coordinator: MediaLibraryCoordinator) async {
        while coordinator.scanState == .scanning {
            await Task.yield()
        }
    }

    private func waitForLoads(
        _ engine: TestPlaybackEngine,
        count: Int
    ) async {
        while engine.loadedSources.count < count {
            await Task.yield()
        }
    }

    private func waitForReady(_ playback: PlaybackCoordinator) async {
        while playback.readiness != .ready {
            await Task.yield()
        }
    }

    private func waitForFailure(_ playback: PlaybackCoordinator) async {
        while true {
            if case .failed = playback.readiness {
                return
            }
            await Task.yield()
        }
    }
}

@MainActor
private struct Fixture {
    let coordinator: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    let engine: TestPlaybackEngine
    let session: TestMediaAccessSession
    let scanner: TestMediaLibraryScanner
}

@MainActor
private final class TestMediaFolderSelector: MediaFolderSelecting {
    let selectedURLs: [URL]

    init(selectedURLs: [URL]) {
        self.selectedURLs = selectedURLs
    }

    func selectFolders() -> [URL] {
        selectedURLs
    }
}

@MainActor
private final class TestMediaAccessSession: MediaAccessSession {
    private(set) var addedURLs: [URL] = []
    var restoredURLs: [URL] = []

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

private final class TestMediaLibraryScanner: MediaLibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: MediaLibrarySnapshot
    private var storedScannedRootURLs: [[URL]] = []

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
}
