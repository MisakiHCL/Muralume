import Foundation
import XCTest
@testable import Muralume

final class PlaybackProgressStoreTests: XCTestCase {
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
