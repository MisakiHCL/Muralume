import XCTest
@testable import Muralume

@MainActor
final class TemporaryPlaybackCompletionTests: XCTestCase {
    private enum TestPolicy {
        static let pollAttempts = 100
        static let pollInterval: Duration = .milliseconds(10)
    }

    func testSingleTemporaryFileRepeatsInEveryPlaybackMode() async throws {
        let item = makeFileItem(
            url: URL(fileURLWithPath: "/tmp/Temporary Repeat.mp4")
        )
        let fixture = makeTemporaryFixture(items: [item])
        defer { fixture.playback.shutdown() }
        let didOpen = await fixture.coordinator.openFilesTemporarily([
            item.url
        ])
        XCTAssertTrue(didOpen)
        try await waitUntilReady(fixture)

        var completionCount = 0
        for mode in PlaybackMode.allCases {
            fixture.coordinator.setPlaybackMode(mode)
            let snapshot = fixture.coordinator.makeQueueSnapshot()
            let revision = fixture.coordinator.queueRevision
            for _ in 0..<2 {
                fixture.engine.emitItemEnded()
                completionCount += 1

                XCTAssertEqual(fixture.engine.loadedSources.count, 1)
                XCTAssertEqual(
                    fixture.engine.soughtTimes,
                    Array(repeating: 0, count: completionCount)
                )
                XCTAssertEqual(
                    fixture.coordinator.makeQueueSnapshot(),
                    snapshot
                )
                XCTAssertEqual(fixture.coordinator.queueRevision, revision)
                XCTAssertEqual(fixture.coordinator.currentItemID, item.id)
                XCTAssertEqual(fixture.coordinator.temporaryItemIDs, [item.id])
                XCTAssertTrue(fixture.playback.isPlaybackRequested)
                XCTAssertTrue(fixture.engine.isPlaying)
            }
        }
        XCTAssertTrue(fixture.coordinator.items.isEmpty)
        await fixture.coordinator.shutdown()
    }

    func testRepeatCurrentTemporaryFilePreservesMultiFileQueue()
        async throws {
        let items = makeTemporaryItems()
        let fixture = makeTemporaryFixture(items: items)
        defer { fixture.playback.shutdown() }
        let didOpen = await fixture.coordinator.openFilesTemporarily(
            items.map(\.url)
        )
        XCTAssertTrue(didOpen)
        try await waitUntilReady(fixture)
        fixture.coordinator.setPlaybackMode(.repeatCurrent)
        let snapshot = fixture.coordinator.makeQueueSnapshot()
        let revision = fixture.coordinator.queueRevision

        fixture.engine.emitItemEnded()
        fixture.engine.emitItemEnded()

        XCTAssertEqual(fixture.engine.loadedSources.count, 1)
        XCTAssertEqual(fixture.engine.soughtTimes, [0, 0])
        XCTAssertEqual(fixture.coordinator.currentItemID, items[0].id)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), snapshot)
        XCTAssertEqual(fixture.coordinator.queueRevision, revision)
        XCTAssertEqual(fixture.coordinator.temporaryItemIDs, Set(items.map(\.id)))
        XCTAssertTrue(fixture.playback.isPlaybackRequested)
        XCTAssertTrue(fixture.engine.isPlaying)
        await fixture.coordinator.shutdown()
    }

    func testTemporaryQueueRestartsAfterLastFileWithBothTransitionStyles()
        async throws {
        for mode in [PlaybackMode.ordered, .shuffled] {
            for isCrossfadeEnabled in [false, true] {
                let items = makeTemporaryItems()
                let fixture = makeTemporaryFixture(items: items)
                fixture.playback.setQueueCrossfadeEnabled(isCrossfadeEnabled)
                fixture.coordinator.setPlaybackMode(mode)
                let didOpen = await fixture.coordinator.openFilesTemporarily(
                    items.map(\.url)
                )
                XCTAssertTrue(didOpen)
                try await waitUntilReady(fixture)

                fixture.engine.emitItemEnded()
                try await waitUntilReady(fixture, loadCount: 2)
                XCTAssertEqual(fixture.coordinator.currentItemID, items[1].id)

                fixture.engine.emitItemEnded()
                try await waitUntilReady(fixture, loadCount: 3)
                XCTAssertEqual(fixture.coordinator.currentItemID, items[0].id)
                XCTAssertEqual(
                    fixture.engine.loadedSources.map(\.url),
                    [items[0].url, items[1].url, items[0].url]
                )
                let transition: PlaybackItemTransition = isCrossfadeEnabled
                    ? .crossfade(duration: PlaybackPolicy.queueCrossfadeDuration)
                    : .immediate
                XCTAssertEqual(
                    fixture.engine.loadedTransitions,
                    [.immediate, transition, transition]
                )
                XCTAssertEqual(
                    fixture.coordinator.temporaryItemIDs,
                    Set(items.map(\.id))
                )
                XCTAssertTrue(fixture.coordinator.items.isEmpty)
                XCTAssertTrue(fixture.playback.isPlaybackRequested)
                XCTAssertTrue(fixture.engine.isPlaying)
                await fixture.coordinator.shutdown()
                fixture.playback.shutdown()
            }
        }
    }

    private func makeTemporaryItems() -> [LibraryMediaItem] {
        ["First", "Second"].map { name in
            makeFileItem(
                url: URL(fileURLWithPath: "/tmp/Temporary \(name).mp4")
            )
        }
    }

    private func makeTemporaryFixture(items: [LibraryMediaItem]) -> Fixture {
        makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: items.map { item in
                    MediaLibraryRoot(
                        url: item.url,
                        displayName: item.displayName,
                        kind: .file
                    )
                },
                items: items
            )
        )
    }

    private func waitUntilReady(
        _ fixture: Fixture,
        loadCount: Int = 1
    ) async throws {
        for _ in 0..<TestPolicy.pollAttempts {
            if fixture.engine.loadedSources.count == loadCount,
               fixture.playback.readiness == .ready {
                return
            }
            try await Task.sleep(for: TestPolicy.pollInterval)
        }
        XCTFail("Temporary playback did not become ready")
        throw CancellationError()
    }
}
