import Foundation
import XCTest
@testable import Muralume

final class PlaybackProgressStoreTests: XCTestCase {
    func testCachedUpdateAppendsOneSmallDurableRecordAtEntryLimit() async throws {
        let directory = temporaryProgressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("progress.json")
        let entries = (0..<PlaybackProgressPolicy.maximumEntryCount).map {
            PlaybackProgressSnapshot.Entry(
                itemID: .init(rootPath: "/Library", relativePath: "\($0).mov"), position: 10
            )
        }
        let legacyData = try JSONEncoder().encode(PlaybackProgressSnapshot(entries: entries))
        try legacyData.write(to: url)
        let probe = ProgressJournalIOProbe(snapshotURL: url)
        let store = FilePlaybackProgressStore(fileURL: url, io: probe.io)
        _ = try await store.position(for: entries[0].itemID)

        try await store.update(position: 20, duration: 120, for: entries[0].itemID)

        XCTAssertEqual(probe.appendCount, 1)
        XCTAssertLessThan(probe.appendedByteCount, 1_024)
        XCTAssertEqual(probe.checkpointCount, 0)
        XCTAssertEqual(try Data(contentsOf: url), legacyData)
        let restored = FilePlaybackProgressStore(fileURL: url)
        let restoredPosition = try await restored.position(for: entries[0].itemID)
        XCTAssertEqual(restoredPosition, 20)

        let overflowID = LibraryMediaItem.ID(rootPath: "/Library", relativePath: "Overflow.mov")
        do {
            try await store.update(position: 20, duration: 120, for: overflowID)
            XCTFail("Expected entry bound")
        } catch let error as PlaybackProgressStoreError {
            guard case .entryLimitExceeded = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(probe.appendCount, 1)
        let overflowPosition = try await store.position(for: overflowID)
        XCTAssertNil(overflowPosition)
    }

    func testCheckpointWatermarkPreventsDeletedEntriesReturningFromOldJournal() async throws {
        let directory = temporaryProgressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let first = LibraryMediaItem.ID(rootPath: "/A", relativePath: "First.mov")
        let second = LibraryMediaItem.ID(rootPath: "/B", relativePath: "Second.mov")
        let store = FilePlaybackProgressStore(fileURL: url)
        try await store.update(position: 10, duration: 120, for: first)
        try await store.update(position: 20, duration: 120, for: second)
        try await store.removeProgress(for: [first])
        let journalURL = FilePlaybackProgressJournal.url(for: url)
        let journalBeforeCheckpoint = try Data(contentsOf: journalURL)
        try await store.compact()
        let snapshot = try JSONDecoder().decode(
            PlaybackProgressSnapshot.self, from: Data(contentsOf: url)
        )
        XCTAssertEqual(snapshot.checkpointSequence, 3)

        // Simulate a crash after snapshot rename but before journal cleanup.
        try journalBeforeCheckpoint.write(to: journalURL, options: .atomic)
        let restored = FilePlaybackProgressStore(fileURL: url)
        let removedPosition = try await restored.position(for: first)
        let keptPosition = try await restored.position(for: second)
        XCTAssertNil(removedPosition)
        XCTAssertEqual(keptPosition, 20)
        try await restored.update(position: 114, duration: 120, for: second)
        let restarted = FilePlaybackProgressStore(fileURL: url)
        let completedPosition = try await restarted.position(for: second)
        XCTAssertNil(completedPosition)
    }

    func testJournalRepairsBadTailBeforeAppendingNextRecord() async throws {
        for tail in [Data("{\"sequence\":2".utf8), Data("invalid-record\n".utf8)] {
            let directory = temporaryProgressDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("progress.json")
            let id = LibraryMediaItem.ID(rootPath: "/Library", relativePath: "Clip.mov")
            let store = FilePlaybackProgressStore(fileURL: url)
            try await store.update(position: 10, duration: 120, for: id)
            let journalURL = FilePlaybackProgressJournal.url(for: url)
            let validData = try Data(contentsOf: journalURL)
            try (validData + tail).write(to: journalURL)

            let restored = FilePlaybackProgressStore(fileURL: url)
            let position = try await restored.position(for: id)
            XCTAssertEqual(position, 10)
            XCTAssertEqual(try Data(contentsOf: journalURL), validData)
            try await restored.update(position: 20, duration: 120, for: id)
            let restarted = FilePlaybackProgressStore(fileURL: url)
            let updatedPosition = try await restarted.position(for: id)
            XCTAssertEqual(updatedPosition, 20)
        }
    }

    func testFailedAppendAndByteBoundLeaveCacheAndRestartStateUnchanged() async throws {
        let directory = temporaryProgressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let first = LibraryMediaItem.ID(rootPath: "/A", relativePath: "First.mov")
        let second = LibraryMediaItem.ID(rootPath: "/B", relativePath: "Second.mov")
        let oneEntryBytes = try JSONEncoder().encode(PlaybackProgressSnapshot(
            entries: [.init(itemID: first, position: 10)], checkpointSequence: 1
        )).count
        let probe = ProgressJournalIOProbe(snapshotURL: url)
        let store = FilePlaybackProgressStore(
            fileURL: url, maximumFileByteCount: oneEntryBytes + 1, io: probe.io
        )
        try await store.update(position: 10, duration: 120, for: first)
        probe.failAppends = true
        do {
            try await store.update(position: 20, duration: 120, for: first)
            XCTFail("Expected failed durable append")
        } catch { }
        let unchangedPosition = try await store.position(for: first)
        XCTAssertEqual(unchangedPosition, 10)
        probe.failAppends = false
        do {
            try await store.update(position: 20, duration: 120, for: second)
            XCTFail("Expected byte bound")
        } catch let error as PlaybackProgressStoreError {
            guard case .fileTooLarge = error else { return XCTFail("Unexpected \(error)") }
        }
        let restored = FilePlaybackProgressStore(fileURL: url)
        let firstPosition = try await restored.position(for: first)
        let secondPosition = try await restored.position(for: second)
        XCTAssertEqual(firstPosition, 10)
        XCTAssertNil(secondPosition)
    }

    func testCheckpointKeepsConcurrentUpdatesAndDeletionWithOneActualWorker() async throws {
        let directory = temporaryProgressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let first = LibraryMediaItem.ID(rootPath: "/A", relativePath: "First.mov")
        let second = LibraryMediaItem.ID(rootPath: "/B", relativePath: "Second.mov")
        let probe = ProgressJournalIOProbe(snapshotURL: url)
        probe.blockNextCheckpoint()
        defer { probe.releaseCheckpoint() }
        let policy = PlaybackProgressJournalPolicy(
            checkpointByteCount: 4_096, maximumByteCount: 8_192,
            checkpointRecordCount: 1, maximumRecordCount: 4
        )
        let store = FilePlaybackProgressStore(fileURL: url, journalPolicy: policy, io: probe.io)
        try await store.update(position: 10, duration: 120, for: first)
        await waitForProgressWork { probe.checkpointCount == 1 }
        try await store.update(position: 20, duration: 120, for: first)
        try await store.removeProgress(for: [first])
        try await store.update(position: 30, duration: 120, for: second)
        XCTAssertEqual(probe.appendCount, 4)
        let atHardCap = Task {
            try await store.update(position: 40, duration: 120, for: second)
        }
        for _ in 0..<64 { await Task.yield() }
        XCTAssertEqual(probe.appendCount, 4)
        XCTAssertEqual(probe.maximumActiveCheckpoints, 1)
        probe.releaseCheckpoint()
        try await atHardCap.value
        try await store.compact()

        let restored = FilePlaybackProgressStore(fileURL: url, journalPolicy: policy)
        let deletedPosition = try await restored.position(for: first)
        let updatedPosition = try await restored.position(for: second)
        XCTAssertNil(deletedPosition)
        XCTAssertEqual(updatedPosition, 40)
        XCTAssertEqual(probe.maximumActiveCheckpoints, 1)
        let journalSize = try Data(contentsOf: FilePlaybackProgressJournal.url(for: url)).count
        XCTAssertLessThanOrEqual(journalSize, policy.maximumByteCount)
    }

    func testPostRenameJournalCleanupFailureDoesNotLoseNextAcknowledgedWrite() async throws {
        try await exercisePostRenameFailure(isSnapshotFailure: false)
    }

    func testPostRenameSnapshotFailureReconcilesWatermarkBeforeNextAcknowledgedWrite() async throws {
        try await exercisePostRenameFailure(isSnapshotFailure: true)
    }

    private func exercisePostRenameFailure(isSnapshotFailure: Bool) async throws {
        let directory = temporaryProgressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("progress.json")
        let entries = (0..<20).map {
            PlaybackProgressSnapshot.Entry(
                itemID: .init(rootPath: "/Library", relativePath: "\($0).mov"), position: 10
            )
        }
        try JSONEncoder().encode(PlaybackProgressSnapshot(entries: entries)).write(to: url)
        let probe = ProgressJournalIOProbe(snapshotURL: url)
        let policy = PlaybackProgressJournalPolicy(
            checkpointByteCount: 512, maximumByteCount: 512,
            checkpointRecordCount: 64, maximumRecordCount: 128
        )
        let store = FilePlaybackProgressStore(fileURL: url, journalPolicy: policy, io: probe.io)
        try await store.update(position: 20, duration: 120, for: entries[0].itemID)
        if isSnapshotFailure {
            probe.failNextCheckpointAfterCommit = true
        } else {
            probe.failNextJournalReplacementAfterCommit = true
        }
        do {
            try await store.removeProgress(for: Set(entries.map(\.itemID)))
            XCTAssertFalse(isSnapshotFailure)
        } catch {
            XCTAssertTrue(isSnapshotFailure)
            let cachedPosition = try await store.position(for: entries[0].itemID)
            XCTAssertEqual(cachedPosition, 20)
        }

        let latestID = LibraryMediaItem.ID(rootPath: "/Library", relativePath: "Latest.mov")
        try await store.update(position: 30, duration: 120, for: latestID)
        let restored = FilePlaybackProgressStore(fileURL: url, journalPolicy: policy)
        let latestPosition = try await restored.position(for: latestID)
        let removedPosition = try await restored.position(for: entries[0].itemID)
        XCTAssertEqual(latestPosition, 30)
        XCTAssertNil(removedPosition)
        let journalData = try Data(contentsOf: FilePlaybackProgressJournal.url(for: url))
        XCTAssertFalse(journalData.contains(0))
    }

    private func temporaryProgressDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func waitForProgressWork(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for progress persistence work")
    }

    func testFileStorePersistsIndependentPositionsAndCompletion() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("progress.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let firstID = LibraryMediaItem.ID(
            rootPath: "/Library",
            relativePath: "Episode 1.mov"
        )
        let secondID = LibraryMediaItem.ID(
            rootPath: "/Library",
            relativePath: "Episode 2.mov"
        )
        let store = FilePlaybackProgressStore(fileURL: fileURL)

        try await store.update(position: 24, duration: 120, for: firstID)
        try await store.update(position: 48, duration: 120, for: secondID)

        let restoredStore = FilePlaybackProgressStore(fileURL: fileURL)
        let firstPosition = try await restoredStore.position(for: firstID)
        let secondPosition = try await restoredStore.position(for: secondID)
        XCTAssertEqual(firstPosition, 24)
        XCTAssertEqual(secondPosition, 48)

        try await restoredStore.update(
            position: 114,
            duration: 120,
            for: firstID
        )

        let completedPosition = try await restoredStore.position(for: firstID)
        let untouchedPosition = try await restoredStore.position(for: secondID)
        XCTAssertNil(completedPosition)
        XCTAssertEqual(untouchedPosition, 48)
    }

    func testFileStorePrunesOnlyMissingItemsWithinCompletedRoots()
        async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("progress.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let keptID = LibraryMediaItem.ID(
            rootPath: "/Complete",
            relativePath: "Kept.mov"
        )
        let removedID = LibraryMediaItem.ID(
            rootPath: "/Complete",
            relativePath: "Removed.mov"
        )
        let unavailableID = LibraryMediaItem.ID(
            rootPath: "/Unavailable",
            relativePath: "Preserved.mov"
        )
        let store = FilePlaybackProgressStore(fileURL: fileURL)
        for itemID in [keptID, removedID, unavailableID] {
            try await store.update(position: 30, duration: 120, for: itemID)
        }

        try await store.pruneProgress(
            keeping: [keptID],
            withinRootPaths: ["/Complete"]
        )

        let keptPosition = try await store.position(for: keptID)
        let removedPosition = try await store.position(for: removedID)
        let unavailablePosition = try await store.position(for: unavailableID)
        XCTAssertEqual(keptPosition, 30)
        XCTAssertNil(removedPosition)
        XCTAssertEqual(unavailablePosition, 30)
    }

    func testFileStoreReplacesCorruptedCacheOnNextUpdate() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("progress.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        let itemID = LibraryMediaItem.ID(
            rootPath: "/Library",
            relativePath: "Episode.mov"
        )
        let store = FilePlaybackProgressStore(fileURL: fileURL)

        try await store.update(position: 24, duration: 120, for: itemID)

        let restoredStore = FilePlaybackProgressStore(fileURL: fileURL)
        let position = try await restoredStore.position(for: itemID)
        XCTAssertEqual(position, 24)
    }
}

private final class ProgressJournalIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let checkpointGate = DispatchSemaphore(value: 0)
    private let snapshotURL: URL
    private var storedAppendCount = 0
    private var storedAppendedByteCount = 0
    private var storedCheckpointCount = 0
    private var activeCheckpoints = 0
    private var peakCheckpoints = 0
    private var shouldBlockCheckpoint = false
    private var shouldFailAppends = false
    private var shouldFailCheckpointAfterCommit = false
    private var shouldFailJournalReplacementAfterCommit = false

    init(snapshotURL: URL) { self.snapshotURL = snapshotURL }
    var appendCount: Int { lock.withLock { storedAppendCount } }
    var appendedByteCount: Int { lock.withLock { storedAppendedByteCount } }
    var checkpointCount: Int { lock.withLock { storedCheckpointCount } }
    var maximumActiveCheckpoints: Int { lock.withLock { peakCheckpoints } }
    var failAppends: Bool {
        get { lock.withLock { shouldFailAppends } }
        set { lock.withLock { shouldFailAppends = newValue } }
    }
    var failNextCheckpointAfterCommit: Bool {
        get { lock.withLock { shouldFailCheckpointAfterCommit } }
        set { lock.withLock { shouldFailCheckpointAfterCommit = newValue } }
    }
    var failNextJournalReplacementAfterCommit: Bool {
        get { lock.withLock { shouldFailJournalReplacementAfterCommit } }
        set { lock.withLock { shouldFailJournalReplacementAfterCommit = newValue } }
    }

    func blockNextCheckpoint() { lock.withLock { shouldBlockCheckpoint = true } }
    func releaseCheckpoint() { checkpointGate.signal() }

    var io: PlaybackProgressJournalIO {
        PlaybackProgressJournalIO(
            append: { [self] url, data, validByteCount in
                if failAppends { throw CocoaError(.fileWriteUnknown) }
                try PlaybackProgressJournalIO.live.append(url, data, validByteCount)
                lock.withLock {
                    storedAppendCount += 1
                    storedAppendedByteCount += data.count
                }
            },
            replace: { [self] url, data in
                guard url == snapshotURL else {
                    let shouldFail = lock.withLock {
                        let flag = shouldFailJournalReplacementAfterCommit
                        shouldFailJournalReplacementAfterCommit = false
                        return flag
                    }
                    try PlaybackProgressJournalIO.live.replace(url, data)
                    if shouldFail { throw CocoaError(.fileWriteUnknown) }
                    return
                }
                let (shouldBlock, shouldFail) = lock.withLock {
                    storedCheckpointCount += 1
                    activeCheckpoints += 1
                    peakCheckpoints = max(peakCheckpoints, activeCheckpoints)
                    let block = shouldBlockCheckpoint
                    shouldBlockCheckpoint = false
                    let fail = shouldFailCheckpointAfterCommit
                    shouldFailCheckpointAfterCommit = false
                    return (block, fail)
                }
                defer { lock.withLock { activeCheckpoints -= 1 } }
                if shouldBlock { checkpointGate.wait() }
                try PlaybackProgressJournalIO.live.replace(url, data)
                if shouldFail { throw CocoaError(.fileWriteUnknown) }
            }
        )
    }
}

@MainActor
final class PlaybackProgressIntegrationTests: XCTestCase {
    func testSwitchingResumesEachVideoFromItsIndependentPosition() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Progress Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "Episode 1",
            path: "Episode 1.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Episode 2",
            path: "Episode 2.mov"
        )
        let store = MemoryPlaybackProgressStore()
        let fixture = makeProgressFixture(
            rootURL: rootURL,
            items: [first, second],
            store: store
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.playback.seek(to: 24)

        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.playback.seek(to: 48)

        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.playback.currentTime, 24)

        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 4)
        await waitForReady(fixture.playback)
        XCTAssertEqual(fixture.playback.currentTime, 48)
    }

    func testSwitchingAtNinetyFivePercentRestartsVideo() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Completed Progress Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "Episode 1",
            path: "Episode 1.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Episode 2",
            path: "Episode 2.mov"
        )
        let store = MemoryPlaybackProgressStore()
        let fixture = makeProgressFixture(
            rootURL: rootURL,
            items: [first, second],
            store: store
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.playback.seek(to: 114)

        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 3)
        await waitForReady(fixture.playback)

        XCTAssertEqual(fixture.playback.currentTime, 0)
        let storedPosition = try? await store.position(for: first.id)
        XCTAssertNil(storedPosition)
    }

    func testResumePositionIsAppliedBeforeAutoplay() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Ordered Progress Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "Episode 1",
            path: "Episode 1.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Episode 2",
            path: "Episode 2.mov"
        )
        let store = MemoryPlaybackProgressStore()
        try await store.update(position: 48, duration: 120, for: second.id)
        let fixture = makeProgressFixture(
            rootURL: rootURL,
            items: [first, second],
            store: store
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        fixture.engine.resetPlaybackEvents()

        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)

        XCTAssertEqual(
            Array(fixture.engine.playbackEvents.prefix(2)),
            [.seek(48), .play]
        )
    }

    func testRemovingRootClearsAllProgressForItsVideos() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Removed Progress Library")
        let first = makeItem(
            rootURL: rootURL,
            name: "Episode 1",
            path: "Episode 1.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Episode 2",
            path: "Episode 2.mov"
        )
        let store = MemoryPlaybackProgressStore()
        for item in [first, second] {
            try await store.update(
                position: 30,
                duration: 120,
                for: item.id
            )
        }
        let fixture = makeProgressFixture(
            rootURL: rootURL,
            items: [first, second],
            store: store
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let root = try XCTUnwrap(fixture.coordinator.roots.first)
        await fixture.coordinator.removeRoot(root)

        let firstPosition = try await store.position(for: first.id)
        let secondPosition = try await store.position(for: second.id)
        XCTAssertNil(firstPosition)
        XCTAssertNil(secondPosition)
    }

    func testIncompleteScanPreservesProgressForTemporarilyMissingVideo()
        async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/Incomplete Progress Library")
        let missing = makeItem(
            rootURL: rootURL,
            name: "Temporarily Missing",
            path: "Temporarily Missing.mov"
        )
        let store = MemoryPlaybackProgressStore()
        try await store.update(
            position: 30,
            duration: 120,
            for: missing.id
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: "Incomplete Progress Library"
                    )
                ],
                items: [],
                incompleteRootPaths: [rootURL.path]
            ),
            playbackProgressStore: store
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        let position = try await store.position(for: missing.id)
        XCTAssertEqual(position, 30)
    }

    private func makeProgressFixture(
        rootURL: URL,
        items: [LibraryMediaItem],
        store: MemoryPlaybackProgressStore
    ) -> Fixture {
        makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [
                    MediaLibraryRoot(
                        url: rootURL,
                        displayName: rootURL.lastPathComponent
                    )
                ],
                items: items
            ),
            playbackProgressStore: store
        )
    }
}

private actor MemoryPlaybackProgressStore: PlaybackProgressStoring {
    private var positions: [LibraryMediaItem.ID: TimeInterval] = [:]

    func position(for itemID: LibraryMediaItem.ID) -> TimeInterval? {
        positions[itemID]
    }

    func update(
        position: TimeInterval,
        duration: TimeInterval,
        for itemID: LibraryMediaItem.ID
    ) {
        positions[itemID] = PlaybackProgressPolicy.resumablePosition(
            position: position,
            duration: duration
        )
    }

    func removeProgress(for itemIDs: Set<LibraryMediaItem.ID>) {
        positions = positions.filter { !itemIDs.contains($0.key) }
    }

    func pruneProgress(
        keeping itemIDs: Set<LibraryMediaItem.ID>,
        withinRootPaths rootPaths: Set<String>
    ) {
        positions = positions.filter { itemID, _ in
            !rootPaths.contains(itemID.rootPath) || itemIDs.contains(itemID)
        }
    }
}
