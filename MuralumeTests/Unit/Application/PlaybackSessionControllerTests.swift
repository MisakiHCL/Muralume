import XCTest
@testable import Muralume

@MainActor
final class PlaybackSessionControllerTests: XCTestCase {
    func testFileStoreRoundTripsAndClearsSnapshot() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 42,
            isPlaying: true,
            presentation: .desktop,
            videoContentMode: .blurredBackground
        )
        let store = FilePlaybackSessionStore(fileURL: fileURL)

        try await store.save(snapshot)
        let restoredSnapshot = try await store.load()
        XCTAssertEqual(restoredSnapshot, snapshot)

        try await store.clear()
        let clearedSnapshot = try await store.load()
        XCTAssertNil(clearedSnapshot)
    }

    func testFileStoreDecodesVersionOneContainSessionFromV102() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("session.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let versionOneJSON = #"""
        {
          "schemaVersion": 1,
          "state": {
            "schemaVersion": 1,
            "queue": {
              "items": [
                { "rootPath": "/tmp/Library", "relativePath": "clip.mp4" }
              ],
              "order": "ordered",
              "currentItem": {
                "rootPath": "/tmp/Library",
                "relativePath": "clip.mp4"
              },
              "roundNumber": 1,
              "currentRoundPosition": 1,
              "remainingItems": [
                { "rootPath": "/tmp/Library", "relativePath": "clip.mp4" }
              ],
              "remainingIndex": 1,
              "history": [],
              "forwardHistory": []
            },
            "currentTime": 24,
            "isPlaybackRequested": false,
            "playbackRateValue": 1,
            "videoContentMode": "contain"
          },
          "presentation": "desktop"
        }
        """#
        try Data(versionOneJSON.utf8).write(to: fileURL)

        let restoredSnapshot = try await FilePlaybackSessionStore(
            fileURL: fileURL
        ).load()

        XCTAssertEqual(restoredSnapshot?.schemaVersion, 1)
        XCTAssertEqual(restoredSnapshot?.state.videoContentMode, .contain)
        XCTAssertEqual(restoredSnapshot?.presentation, .desktop)
        XCTAssertTrue(restoredSnapshot?.isValid == true)
    }

    func testPlayerRestoreResumesCurrentItemTimeAndPlayback() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 42,
            isPlaying: true,
            presentation: .player
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.library.currentItemID, items[1].id)
        XCTAssertEqual(fixture.playback.currentTime, 42)
        XCTAssertEqual(fixture.engine.soughtTimes.last, 42)
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .player)
        XCTAssertFalse(
            fixture.applicationPresence.appliedModes.contains(.menuBarOnly)
        )

        await shutdown(fixture)
    }

    func testPausedPlayerRestoreNeverRequestsTransientPlayback() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 18,
            isPlaying: false,
            presentation: .player
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.engine.playCallCount, 0)
        XCTAssertFalse(fixture.engine.isPlaying)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)

        await shutdown(fixture)
    }

    func testCancelledRestoreAdoptsPlayerAndDeferredPlayingIntent()
        async throws
    {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 18,
            isPlaying: true,
            presentation: .desktop
        )
        let store = MemoryPlaybackSessionStore(snapshot: snapshot)
        let fixture = makeFixture(items: items, store: store)

        let planResult = await fixture.controller.makeRestorePlan()
        guard case .restore = planResult else {
            XCTFail("Expected a restorable playback session.")
            return
        }
        let libraryStart = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: libraryStart)
        let queueResult = await fixture.library.restoreQueue(
            from: snapshot.state.queue,
            attachToPlayerSurface: true
        )
        fixture.controller.finishCancelledRestoreIfNeeded()

        XCTAssertEqual(queueResult, .restored)
        XCTAssertFalse(fixture.playback.isPlaybackRequested)

        await fixture.controller
            .adoptPlayerPresentationAfterCancelledRestore()
        let storedSnapshot = await store.value()

        XCTAssertEqual(storedSnapshot?.presentation, .player)
        XCTAssertTrue(
            storedSnapshot?.state.isPlaybackRequested == true
        )
        XCTAssertTrue(fixture.playback.isPlaybackRequested)

        await shutdown(fixture)
    }

    func testDesktopRestoreEntersActiveMenuBarOnlyPresentation() async throws {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 24,
            isPlaying: true,
            presentation: .desktop
        )
        let fixture = makeFixture(items: items, snapshot: snapshot)

        let result = await restoreStoredSession(in: fixture)

        XCTAssertEqual(result, .restored)
        XCTAssertTrue(fixture.desktopSession.isActive)
        XCTAssertEqual(fixture.playback.presentation, .desktop)
        XCTAssertEqual(
            fixture.applicationPresence.appliedModes.last,
            .menuBarOnly
        )
        XCTAssertEqual(fixture.engine.attachedSurfaceIDs.last, .desktop)

        await shutdown(fixture)
    }

    func testNormalShutdownPersistsActiveDesktopPresentation() async throws {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)

        let didEnterDesktop = await fixture.desktopSession.enterDesktopAndWait()
        await fixture.controller.prepareForShutdown()
        let storedSnapshot = await store.value()

        XCTAssertTrue(didEnterDesktop)
        XCTAssertEqual(storedSnapshot?.presentation, .desktop)
        XCTAssertEqual(storedSnapshot?.state.queue.currentItem, items[0].id)
        XCTAssertTrue(storedSnapshot?.isValid == true)

        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testShutdownDuringReturnPersistsPlayerDestination() async throws {
        let items = makeItems()
        let store = MemoryPlaybackSessionStore(snapshot: nil)
        let fixture = makeFixture(items: items, store: store)
        await prepareActiveQueue(items[0], in: fixture)
        let didEnterDesktop = await fixture.desktopSession.enterDesktopAndWait()
        XCTAssertTrue(didEnterDesktop)

        fixture.engine.blockPlayerAttachment()
        fixture.desktopSession.returnToPlayer()
        await waitUntil {
            if case .switching(_, destination: .player) =
                fixture.playback.presentation {
                return true
            }
            return false
        }

        await fixture.controller.prepareForShutdown()
        let storedSnapshot = await store.value()

        XCTAssertTrue(fixture.desktopSession.isActive)
        XCTAssertEqual(storedSnapshot?.presentation, .player)

        fixture.engine.finishBlockedPlayerAttachment()
        await waitUntil {
            !fixture.desktopSession.isTransitioning
        }
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    func testOrdinarySaveFailureKeepsLastKnownGoodSnapshot() async throws {
        let items = makeItems()
        let lastKnownGood = try makeSnapshot(
            items: items,
            currentItem: items[1],
            currentTime: 7,
            isPlaying: false,
            presentation: .player
        )
        let store = MemoryPlaybackSessionStore(snapshot: lastKnownGood)
        await store.setSaveFailure(true)
        let fixture = makeFixture(items: items, store: store)

        await prepareActiveQueue(items[0], in: fixture)
        await waitUntil {
            fixture.controller.persistenceFailure == .saveFailed
        }
        let preservedSnapshot = await store.value()
        let clearCount = await store.clearCount

        XCTAssertEqual(preservedSnapshot, lastKnownGood)
        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(fixture.controller.persistenceFailure, .saveFailed)

        await shutdown(fixture)
    }

    func testTemporaryRestorePreservesSnapshotAndPermanentFailureClearsIt()
        async throws
    {
        let items = makeItems()
        let snapshot = try makeSnapshot(
            items: items,
            currentItem: items[0],
            currentTime: 11,
            isPlaying: true,
            presentation: .player
        )
        let temporaryStore = MemoryPlaybackSessionStore(snapshot: snapshot)
        let temporaryFixture = makeFixture(
            items: [],
            scannedRoots: [],
            store: temporaryStore
        )

        let temporaryResult = await restoreStoredSession(
            in: temporaryFixture
        )
        let changedRate = try XCTUnwrap(PlaybackPolicy.supportedRates.last)
        temporaryFixture.playback.setRate(changedRate)
        await temporaryFixture.controller.prepareForShutdown()
        let preservedSnapshot = await temporaryStore.value()

        XCTAssertEqual(temporaryResult, .temporarilyUnavailable)
        XCTAssertEqual(preservedSnapshot, snapshot)

        temporaryFixture.desktopSession.shutdown()
        await temporaryFixture.library.shutdown()

        let permanentStore = MemoryPlaybackSessionStore(snapshot: snapshot)
        let permanentFixture = makeFixture(
            items: [],
            scannedRoots: [
                MediaLibraryRoot(
                    url: items[0].rootURL,
                    displayName: "Library"
                )
            ],
            store: permanentStore
        )

        let permanentResult = await restoreStoredSession(in: permanentFixture)
        let clearedSnapshot = await permanentStore.value()
        let permanentClearCount = await permanentStore.clearCount

        XCTAssertEqual(permanentResult, .permanentlyUnavailable)
        XCTAssertNil(clearedSnapshot)
        XCTAssertEqual(permanentClearCount, 1)

        await shutdown(permanentFixture)
    }

    private func restoreStoredSession(
        in fixture: PlaybackSessionFixture
    ) async -> PlaybackStateRestoreResult {
        let planResult = await fixture.controller.makeRestorePlan()
        guard case let .restore(plan) = planResult else {
            XCTFail("Expected a restorable playback session, got \(planResult)")
            return .cancelled
        }

        return await fixture.controller.restore(
            plan,
            after: fixture.library.start()
        )
    }

    private func prepareActiveQueue(
        _ item: LibraryMediaItem,
        in fixture: PlaybackSessionFixture
    ) async {
        let start = fixture.library.start()
        _ = await fixture.library.waitForStartupScan(after: start)
        fixture.library.play(item)
        await waitUntil {
            fixture.playback.readiness == .ready
        }
    }

    private func shutdown(_ fixture: PlaybackSessionFixture) async {
        await fixture.controller.prepareForShutdown()
        fixture.desktopSession.shutdown()
        await fixture.library.shutdown()
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for playback session state.")
    }

    private func makeFixture(
        items: [LibraryMediaItem],
        scannedRoots: [MediaLibraryRoot]? = nil,
        snapshot: PlaybackSessionSnapshot? = nil,
        store suppliedStore: MemoryPlaybackSessionStore? = nil
    ) -> PlaybackSessionFixture {
        let rootURL = makeItems()[0].rootURL
        let engine = SessionPlaybackEngine()
        let playback = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        playback.registerPlayerSurface(playerSurface)
        let library = MediaLibraryCoordinator(
            playback: playback,
            folderSelector: SessionFolderSelector(),
            mediaSession: SessionMediaAccessSession(rootURLs: [rootURL]),
            scanner: SessionMediaScanner(
                snapshot: MediaLibrarySnapshot(
                    roots: scannedRoots ?? [
                        MediaLibraryRoot(
                            url: rootURL,
                            displayName: "Library"
                        )
                    ],
                    items: items
                )
            ),
            mediaThumbnailProvider: TestMediaThumbnailProvider(),
            playbackOrder: .ordered
        )
        let applicationPresence = TestApplicationPresenceController()
        let desktopSession = DesktopSessionCoordinator(
            playback: playback,
            desktopHost: TestDesktopHost(),
            statusMenu: TestDesktopStatusPresenter(),
            videoContentModeStore: TestDesktopVideoContentModeStore(),
            lifecycleMonitor: TestSystemLifecycleMonitor(),
            mainWindow: TestMainWindowPresenter(),
            applicationPresence: applicationPresence
        )
        let store = suppliedStore
            ?? MemoryPlaybackSessionStore(snapshot: snapshot)
        let controller = PlaybackSessionController(
            playback: playback,
            library: library,
            desktopSession: desktopSession,
            store: store
        )
        return PlaybackSessionFixture(
            controller: controller,
            library: library,
            playback: playback,
            desktopSession: desktopSession,
            engine: engine,
            applicationPresence: applicationPresence,
            playerSurface: playerSurface
        )
    }

    private func makeItems() -> [LibraryMediaItem] {
        let rootURL = URL(
            fileURLWithPath: "/tmp/PlaybackSessionControllerTests/Library"
        )
        return [
            makeItem(rootURL: rootURL, name: "First", path: "first.mp4"),
            makeItem(rootURL: rootURL, name: "Second", path: "second.mp4")
        ]
    }

    private func makeItem(
        rootURL: URL,
        name: String,
        path: String
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent(path),
            displayName: name,
            relativePath: path,
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
    }

    private func makeSnapshot(
        items: [LibraryMediaItem],
        currentItem: LibraryMediaItem,
        currentTime: TimeInterval,
        isPlaying: Bool,
        presentation: PlaybackSessionPresentation,
        videoContentMode: DesktopVideoContentMode = .cover
    ) throws -> PlaybackSessionSnapshot {
        let queue = PlaybackQueue(
            items: items.map(\.id),
            startingAt: currentItem.id,
            order: .ordered
        )
        return PlaybackSessionSnapshot(
            state: DesktopPreset(
                queue: try XCTUnwrap(queue.makeSnapshot()),
                currentTime: currentTime,
                isPlaybackRequested: isPlaying,
                playbackRate: PlaybackPolicy.defaultRate,
                videoContentMode: videoContentMode
            ),
            presentation: presentation
        )
    }
}

@MainActor
private struct PlaybackSessionFixture {
    let controller: PlaybackSessionController
    let library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    let desktopSession: DesktopSessionCoordinator
    let engine: SessionPlaybackEngine
    let applicationPresence: TestApplicationPresenceController
    // PlaybackCoordinator retains render surfaces weakly.
    let playerSurface: TestPlaybackSurface
}

@MainActor
private final class SessionFolderSelector: MediaFolderSelecting {
    func selectFolders() -> [URL] {
        []
    }
}

@MainActor
private final class SessionMediaAccessSession: MediaAccessSession {
    private let rootURLs: [URL]

    init(rootURLs: [URL]) {
        self.rootURLs = rootURLs
    }

    func restoreFolders() -> [URL] {
        rootURLs
    }

    func addFolders(_ urls: [URL]) -> [URL] {
        rootURLs
    }

    func removeFolder(_ url: URL) -> [URL] {
        rootURLs.filter { $0 != url }
    }

    func stop() {}
}

private final class SessionMediaScanner:
    MediaLibraryScanning,
    @unchecked Sendable
{
    private let snapshot: MediaLibrarySnapshot

    init(snapshot: MediaLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        snapshot
    }
}

@MainActor
private final class SessionPlaybackEngine: PlaybackEngine {
    var progressHandler: ((TimeInterval) -> Void)?
    var itemEndedHandler: (() -> Void)?
    var failureHandler: ((PlaybackEngineError) -> Void)?
    var playbackActivityHandler: ((Bool) -> Void)?

    private(set) var attachedSurfaceIDs: [PlaybackSurfaceID] = []
    private(set) var soughtTimes: [TimeInterval] = []
    private(set) var playCallCount = 0
    private(set) var isPlaying = false
    private var shouldBlockPlayerAttachment = false
    private var playerAttachmentContinuation:
        CheckedContinuation<Void, Never>?

    func load(_ source: ResolvedMediaSource) async throws -> TimeInterval {
        120
    }

    func attach(to surface: any PlaybackRenderSurface) async throws {
        attachedSurfaceIDs.append(surface.id)
        guard surface.id == .player,
              shouldBlockPlayerAttachment else {
            return
        }
        await withCheckedContinuation { continuation in
            playerAttachmentContinuation = continuation
        }
    }

    func blockPlayerAttachment() {
        shouldBlockPlayerAttachment = true
    }

    func finishBlockedPlayerAttachment() {
        shouldBlockPlayerAttachment = false
        playerAttachmentContinuation?.resume()
        playerAttachmentContinuation = nil
    }

    func detachAll() {}

    func play(at rate: PlaybackRate) {
        playCallCount += 1
        isPlaying = true
        playbackActivityHandler?(true)
    }

    func pause() {
        isPlaying = false
        playbackActivityHandler?(false)
    }

    func seek(to seconds: TimeInterval) {
        soughtTimes.append(seconds)
    }

    func setVolume(_ volume: PlaybackVolume) {}

    func setMuted(_ isMuted: Bool) {}

    func stop() {
        isPlaying = false
        playbackActivityHandler?(false)
    }
}

private enum MemoryPlaybackSessionStoreError: Error {
    case saveFailed
}

private actor MemoryPlaybackSessionStore: PlaybackSessionStoring {
    private var snapshot: PlaybackSessionSnapshot?
    private var shouldFailSave = false
    private(set) var clearCount = 0

    init(snapshot: PlaybackSessionSnapshot?) {
        self.snapshot = snapshot
    }

    func setSaveFailure(_ shouldFail: Bool) {
        shouldFailSave = shouldFail
    }

    func value() -> PlaybackSessionSnapshot? {
        snapshot
    }

    func load() throws -> PlaybackSessionSnapshot? {
        snapshot
    }

    func save(_ snapshot: PlaybackSessionSnapshot) throws {
        if shouldFailSave {
            throw MemoryPlaybackSessionStoreError.saveFailed
        }
        self.snapshot = snapshot
    }

    func clear() {
        clearCount += 1
        snapshot = nil
    }
}
