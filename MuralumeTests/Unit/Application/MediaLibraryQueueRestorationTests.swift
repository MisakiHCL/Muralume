import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryQueueRestorationTests: XCTestCase {
    func testPreparationSharesIndexOffMainAndKeepsOnlyLatestPendingRequest()
        async throws {
        let preparer = GatedQueueRestorationPreparer(blockedCalls: [1])
        let (fixture, items) = try await startedFixture(preparer: preparer)
        defer { preparer.releaseAll() }
        let snapshot = try queueSnapshot(items)
        var attempt = restore(fixture, snapshot: snapshot)
        guard await eventually({ preparer.observations.count == 1 }) else { return }
        for _ in 0..<100 {
            let previous = attempt
            attempt = restore(fixture, snapshot: snapshot)
            guard await eventually({ previous.result.value != nil }) else {
                preparer.releaseAll()
                attempt.task.cancel()
                return
            }
            XCTAssertEqual(previous.result.value, .cancelled)
        }
        XCTAssertEqual(preparer.observations.count, 1)
        XCTAssertEqual(preparer.maximumActiveCount, 1)
        XCTAssertFalse(preparer.observations[0].ranOnMainThread)
#if DEBUG
        XCTAssertEqual(
            preparer.observations[0].indexIdentity,
            fixture.coordinator.mediaReferenceResolutionIndex.storageIdentityForTesting
        )
#endif
        preparer.release(call: 1)
        guard await eventually({ attempt.result.value != nil }) else { return }
        XCTAssertEqual(attempt.result.value, .restored)
        XCTAssertEqual(preparer.observations.count, 2)
        XCTAssertEqual(preparer.maximumActiveCount, 1)
        XCTAssertTrue(preparer.observations.allSatisfy { !$0.ranOnMainThread })
        XCTAssertEqual(fixture.coordinator.currentItemID, items[0].id)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [items[0].url])
        await fixture.coordinator.shutdown()
    }

    func testSelectionDuringPreparationWinsWithoutLoadingRestoredItem()
        async throws {
        let preparer = GatedQueueRestorationPreparer(blockedCalls: [1])
        let (fixture, items) = try await startedFixture(preparer: preparer)
        defer { preparer.releaseAll() }
        let attempt = restore(fixture, snapshot: try queueSnapshot(items))
        guard await eventually({ preparer.observations.count == 1 }) else { return }
        fixture.coordinator.playLibraryItem(items[1])
        guard await eventually({ fixture.playback.readiness == .ready }) else { return }
        preparer.release(call: 1)
        guard await eventually({ attempt.result.value != nil }) else { return }
        XCTAssertEqual(attempt.result.value, .cancelled)
        XCTAssertEqual(fixture.coordinator.currentItemID, items[1].id)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [items[1].url])
        XCTAssertEqual(Set(fixture.coordinator.makeQueueSnapshot()?.items ?? []),
                       Set(items.map(\.id)))
        await fixture.coordinator.shutdown()
    }

    func testPlaylistEditsAndDeletionRetryButExplicitItemsRemainASnapshot()
        async throws {
        let preparer = GatedQueueRestorationPreparer(blockedCalls: [1, 3, 5])
        let (fixture, items) = try await startedFixture(preparer: preparer)
        defer { preparer.releaseAll() }
        let playlistID = CustomPlaylist.ID(rawValue: UUID())
        var providerItems: [LibraryMediaItem]? = [items[0], items[1]]
        fixture.coordinator.customPlaylistItemsProvider = { id in
            id == playlistID ? providerItems : nil
        }
        let original = try queueSnapshot([items[0], items[1]])
        let edit = restore(fixture, snapshot: original, collection: .customPlaylist(playlistID))
        guard await eventually({ preparer.observations.count == 1 }) else { return }
        providerItems = [items[1], items[2]]
        preparer.release(call: 1)
        guard await eventually({ edit.result.value != nil }) else { return }
        XCTAssertEqual(edit.result.value, .restored)
        XCTAssertEqual(preparer.observations.count, 2)
        XCTAssertEqual(preparer.observations[1].collectionIDs, [items[1].id, items[2].id])
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items,
                       [items[1].id, items[2].id])
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .customPlaylist(playlistID))

        let deletion = restore(
            fixture,
            snapshot: try XCTUnwrap(fixture.coordinator.makeQueueSnapshot()),
            collection: .customPlaylist(playlistID)
        )
        guard await eventually({ preparer.observations.count == 3 }) else { return }
        providerItems = nil
        preparer.release(call: 3)
        guard await eventually({ deletion.result.value != nil }) else { return }
        XCTAssertEqual(deletion.result.value, .restored)
        XCTAssertEqual(preparer.observations.count, 4)
        XCTAssertNil(preparer.observations[3].collectionIDs)
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .fixed)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items,
                       [items[1].id, items[2].id])

        let explicit = restore(
            fixture, snapshot: original, collection: .customPlaylist(playlistID),
            explicitItems: [items[0], items[1]]
        )
        guard await eventually({ preparer.observations.count == 5 }) else { return }
        providerItems = [items[2]]
        preparer.release(call: 5)
        guard await eventually({ explicit.result.value != nil }) else { return }
        XCTAssertEqual(explicit.result.value, .restored)
        XCTAssertEqual(preparer.observations.count, 5)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items,
                       [items[0].id, items[1].id])
        XCTAssertEqual(fixture.coordinator.activePlaybackCollection, .customPlaylist(playlistID))
        await fixture.coordinator.shutdown()
    }

    func testLibraryChangeRetriesUsingLatestPreparedIndex() async throws {
        let preparer = GatedQueueRestorationPreparer(blockedCalls: [1])
        let (fixture, items) = try await startedFixture(preparer: preparer)
        defer { preparer.releaseAll() }
        let attempt = restore(fixture, snapshot: try queueSnapshot([items[0], items[1]]))
        guard await eventually({ preparer.observations.count == 1 }) else { return }
        fixture.scanner.enqueueSnapshot(MediaLibrarySnapshot(
            roots: [MediaLibraryRoot(url: items[0].rootURL, displayName: "Library")],
            items: [items[1], items[2]]
        ))
        fixture.coordinator.refresh()
        guard await eventually({ fixture.coordinator.scanState == .ready
            && fixture.coordinator.items.count == 2 }) else { return }
        preparer.release(call: 1)
        guard await eventually({ attempt.result.value != nil }) else { return }
        XCTAssertEqual(attempt.result.value, .restored)
        XCTAssertEqual(preparer.observations.count, 2)
#if DEBUG
        XCTAssertNotEqual(preparer.observations[0].indexIdentity,
                          preparer.observations[1].indexIdentity)
        XCTAssertEqual(preparer.observations[1].indexIdentity,
                       fixture.coordinator.mediaReferenceResolutionIndex.storageIdentityForTesting)
#endif
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot()?.items, [items[1].id])
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [items[1].url])
        await fixture.coordinator.shutdown()
    }

    func testInvalidSnapshotPreservesQueueWhileValidMissingQueueClearsIt()
        async throws {
        let (fixture, items) = try await startedFixture()
        fixture.coordinator.playLibraryItem(items[1])
        guard await eventually({ fixture.playback.readiness == .ready }) else { return }
        let before = fixture.coordinator.makeQueueSnapshot()
        let invalid = PlaybackQueueSnapshot(
            items: [items[0].id, items[1].id], order: .ordered,
            currentItem: items[0].id, roundNumber: 1, currentRoundPosition: 1,
            remainingItems: [items[1].id, items[1].id], remainingIndex: 0,
            history: [], forwardHistory: []
        )
        let invalidResult = await fixture.coordinator.restoreQueue(from: invalid)
        XCTAssertEqual(invalidResult, .permanentlyUnavailable)
        XCTAssertEqual(fixture.coordinator.makeQueueSnapshot(), before)
        XCTAssertEqual(fixture.engine.loadedSources.map(\.url), [items[1].url])

        let missing = makeItem(rootURL: items[0].rootURL, name: "Deleted", path: "Deleted.mov")
        let missingResult = await fixture.coordinator.restoreQueue(
            from: try queueSnapshot([missing])
        )
        XCTAssertEqual(missingResult, .permanentlyUnavailable)
        XCTAssertNil(fixture.coordinator.currentItemID)
        XCTAssertFalse(fixture.coordinator.hasActiveQueue)
        XCTAssertEqual(fixture.playback.readiness, .empty)
        await fixture.coordinator.shutdown()
    }

    private func startedFixture(
        preparer: any MediaLibraryQueueRestorationPreparing = DefaultMediaLibraryQueueRestorationPreparer()
    ) async throws -> (Fixture, [LibraryMediaItem]) {
        let rootURL = URL(fileURLWithPath: "/tmp/QueueRestorationRegression")
        let items = ["A", "B", "C"].map {
            makeItem(rootURL: rootURL, name: $0, path: "\($0).mov")
        }
        let fixture = makeFixture(
            selectedURLs: [],
            snapshot: MediaLibrarySnapshot(
                roots: [MediaLibraryRoot(url: rootURL, displayName: "Library")],
                items: items
            ), queueRestorationPreparer: preparer
        )
        fixture.session.restoredURLs = [rootURL]
        _ = fixture.coordinator.start()
        guard await eventually({ fixture.coordinator.scanState == .ready }) else {
            throw QueueRestorationTestError.deadline
        }
        return (fixture, items)
    }

    private func queueSnapshot(_ items: [LibraryMediaItem]) throws
        -> PlaybackQueueSnapshot<LibraryMediaItem.ID> {
        try XCTUnwrap(PlaybackQueue(items: items.map(\.id), order: .ordered).makeSnapshot())
    }

    private func restore(
        _ fixture: Fixture,
        snapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        collection: PlaybackCollection = .mediaLibrary,
        explicitItems: [LibraryMediaItem]? = nil
    ) -> (task: Task<MediaLibraryQueueRestoreResult, Never>, result: QueueRestoreTestResult) {
        let result = QueueRestoreTestResult()
        let task = Task {
            let value = await fixture.coordinator.restoreQueue(
                from: snapshot, playbackCollection: collection, collectionItems: explicitItems
            )
            result.value = value
            return value
        }
        return (task, result)
    }

    @discardableResult
    private func eventually(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Queue restoration did not reach its expected state", file: file, line: line)
        return false
    }
}

private enum QueueRestorationTestError: Error { case deadline }

@MainActor
private final class QueueRestoreTestResult {
    var value: MediaLibraryQueueRestoreResult?
}

private final class GatedQueueRestorationPreparer:
    MediaLibraryQueueRestorationPreparing, @unchecked Sendable {
    struct Observation {
        let ranOnMainThread: Bool
        let collectionIDs: [LibraryMediaItem.ID]?
#if DEBUG
        let indexIdentity: UUID
#endif
    }

    private let lock = NSLock()
    private let blockedCalls: Set<Int>
    private var releasedCalls: Set<Int> = []
    private var isReleased = false
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var storedObservations: [Observation] = []
    private var activeCount = 0
    private var storedMaximumActiveCount = 0

    init(blockedCalls: Set<Int>) { self.blockedCalls = blockedCalls }

    var observations: [Observation] { lock.withLock { storedObservations } }
    var maximumActiveCount: Int { lock.withLock { storedMaximumActiveCount } }

    func prepare(_ request: MediaLibraryQueueRestoreRequest) async throws
        -> MediaLibraryQueueRestorePreparation {
#if DEBUG
        let observation = Observation(
            ranOnMainThread: Self.isMainThreadSnapshot(),
            collectionIDs: request.collectionItems?.map(\.id),
            indexIdentity: request.resolutionIndex.storageIdentityForTesting
        )
#else
        let observation = Observation(
            ranOnMainThread: Self.isMainThreadSnapshot(),
            collectionIDs: request.collectionItems?.map(\.id)
        )
#endif
        let call = lock.withLock {
            storedObservations.append(observation)
            activeCount += 1
            storedMaximumActiveCount = max(storedMaximumActiveCount, activeCount)
            return storedObservations.count
        }
        defer { lock.withLock { activeCount -= 1 } }
        if blockedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if isReleased || releasedCalls.contains(call) { return true }
                    continuations[call] = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        return try await DefaultMediaLibraryQueueRestorationPreparer().prepare(request)
    }

    private static func isMainThreadSnapshot() -> Bool { Thread.isMainThread }

    func release(call: Int) {
        let continuation = lock.withLock {
            releasedCalls.insert(call)
            return continuations.removeValue(forKey: call)
        }
        continuation?.resume()
    }

    func releaseAll() {
        let pending = lock.withLock {
            isReleased = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        pending.forEach { $0.resume() }
    }
}
