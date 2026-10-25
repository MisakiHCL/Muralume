import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryRemovalPreparationTests: XCTestCase {
    func testWorkerLeaseUsesOriginalSourceURLAndBalancesClaims() throws {
        let original = URL(fileURLWithPath: "/tmp/Lease/../Original")
        let root = makeRoot(original)
        let request = MediaLibraryRemovalRequest(
            root: root, remainingSources: [], sourceAccessURLs: [original],
            library: .init(items: [], itemsByID: [:]), queue: nil, currentItemID: nil,
            queueItemsByID: [:], unavailableItemIDs: [], supersededThumbnailRootPaths: []
        )
        let probe = RemovalAccessProbe()
        var lease: MediaLibraryRemovalScopeLease? = MediaLibraryRemovalScopeLease(
            startAccess: { probe.start($0); return true }, stopAccess: { probe.stop($0) }
        )
        try lease?.acquire(for: request)
        XCTAssertEqual(probe.started, [original])
        XCTAssertTrue(probe.stopped.isEmpty)
        lease = nil
        XCTAssertEqual(probe.stopped, [original])
    }

    func testConcurrentRemovalsRemainDurableAfterCallingViewTaskIsCancelled() async {
        let roots = ["Removal First", "Removal Second", "Removal Retained"].map {
            makeRoot(URL(fileURLWithPath: "/tmp/\($0)"))
        }
        let items = roots.enumerated().map { index, root in
            makeItem(rootURL: root.url, name: "\(index)", path: "\(index).mov")
        }
        let preparer = GatedRemovalPreparer()
        let fixture = makeFixture(
            selectedURLs: roots.map(\.url), snapshot: .init(roots: roots, items: items),
            removalPreparer: preparer
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let first = Task { await fixture.coordinator.removeRoot(roots[0]) }
        guard await waitForPreparation(preparer) else {
            await preparer.release()
            await first.value
            await fixture.coordinator.shutdown()
            return XCTFail("Removal worker did not start")
        }
        let second = Task { await fixture.coordinator.removeRoot(roots[1]) }
        first.cancel()
        for _ in 0..<100 { await Task.yield() }
        await preparer.release()
        await first.value
        await second.value
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(Set(fixture.session.removedURLs), Set(roots.prefix(2).map(\.url)))
        XCTAssertEqual(fixture.coordinator.roots.map(\.id), [roots[2].id])
        XCTAssertEqual(fixture.coordinator.items.map(\.id), [items[2].id])
        await fixture.coordinator.shutdown()
    }

    func testRemovalPreparesOffMainThreadAndPreservesNewerPlaybackSelection() async throws {
        let removed = makeRoot(URL(fileURLWithPath: "/tmp/Removal Background"))
        let retained = makeRoot(URL(fileURLWithPath: "/tmp/Retained Background"))
        let first = makeItem(rootURL: removed.url, name: "A", path: "A.mov")
        let second = makeItem(rootURL: retained.url, name: "B", path: "B.mov")
        let third = makeItem(rootURL: retained.url, name: "C", path: "C.mov")
        let preparer = GatedRemovalPreparer()
        let fixture = makeFixture(
            selectedURLs: [removed.url, retained.url],
            snapshot: .init(roots: [removed, retained], items: [first, second, third]),
            removalPreparer: preparer
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(second)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)
        let removal = Task { await fixture.coordinator.removeRoot(removed) }
        guard await waitForPreparation(preparer) else {
            await preparer.release()
            await removal.value
            await fixture.coordinator.shutdown()
            return XCTFail("Removal worker did not start")
        }
        // This executes while preparation is suspended. Its result must not
        // be overwritten by the queue captured before the worker started.
        fixture.coordinator.play(third)
        await preparer.release()
        await removal.value
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.currentItemID, third.id)
        XCTAssertEqual(fixture.coordinator.items.map(\.id), [second.id, third.id])
        let state = await preparer.state
        XCTAssertGreaterThanOrEqual(state.calls, 2)
        XCTAssertFalse(state.didRunOnMainThread)
        XCTAssertEqual(fixture.session.removedURLs, [removed.url])
        await fixture.coordinator.shutdown()
    }

    func testShutdownCancelsCallerWhileBlockedRemovalWorkerRetainsOwnScope() async {
        let root = makeRoot(URL(fileURLWithPath: "/tmp/Removal Shutdown"))
        let item = makeItem(rootURL: root.url, name: "A", path: "A.mov")
        let preparer = GatedRemovalPreparer()
        let fixture = makeFixture(
            selectedURLs: [root.url], snapshot: .init(roots: [root], items: [item]),
            removalPreparer: preparer
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let removal = Task { await fixture.coordinator.removeRoot(root) }
        guard await waitForPreparation(preparer) else {
            await preparer.release()
            await removal.value
            await fixture.coordinator.shutdown()
            return XCTFail("Removal worker did not start")
        }
        let shutdown = Task { await fixture.coordinator.shutdown() }
        for _ in 0..<10_000 {
            if fixture.session.stopCount == 1 { break }
            await Task.yield()
        }
        // Cancelling the worker must release shutdown without waiting for
        // non-cooperative I/O. Its independent access lease lives until it
        // really exits, and a late result cannot publish after shutdown.
        XCTAssertEqual(fixture.session.stopCount, 1)
        let revisionAfterShutdown = fixture.coordinator.itemsRevision
        await preparer.release()
        await removal.value
        await shutdown.value
        XCTAssertEqual(fixture.session.stopCount, 1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.itemsRevision, revisionAfterShutdown)
    }

    func testRemovalPlanRetainsCoveredSourcesAndSkipsUnavailableSuccessor() async throws {
        let root = makeRoot(URL(fileURLWithPath: "/Library"))
        let retainedRoot = makeRoot(URL(fileURLWithPath: "/Other"))
        let removed = makeItem(rootURL: root.url, name: "A", path: "A.mov")
        let unavailable = makeItem(rootURL: retainedRoot.url, name: "B", path: "B.mov")
        let available = makeItem(rootURL: retainedRoot.url, name: "C", path: "C.mov")
        let items = [removed, unavailable, available]
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let request = MediaLibraryRemovalRequest(
            root: root, remainingSources: [.init(url: retainedRoot.url, kind: .folder)],
            sourceAccessURLs: [root.url, retainedRoot.url],
            library: .init(items: items, itemsByID: byID),
            queue: PlaybackQueue(items: items.map(\.id)), currentItemID: removed.id,
            queueItemsByID: byID, unavailableItemIDs: [unavailable.id],
            supersededThumbnailRootPaths: [root.url.appendingPathComponent("old.mov").path]
        )
        let plan = try await DefaultMediaLibraryRemovalPreparer().prepare(request)
        XCTAssertEqual(plan.removedItemIDs, [removed.id])
        XCTAssertEqual(plan.library.items.map(\.id), [unavailable.id, available.id])
        XCTAssertEqual(plan.queue?.currentItem, available.id)
        XCTAssertEqual(Set(plan.queueItemsByID.keys), [unavailable.id, available.id])
        XCTAssertEqual(plan.thumbnailRootIDs.count, 2)
        XCTAssertTrue(plan.removedCurrentItem)
        let covered = MediaLibraryRemovalRequest(
            root: root, remainingSources: [.init(url: root.url, kind: .folder)],
            sourceAccessURLs: [root.url],
            library: request.library, queue: request.queue, currentItemID: removed.id,
            queueItemsByID: byID, unavailableItemIDs: [], supersededThumbnailRootPaths: []
        )
        let retained = try await DefaultMediaLibraryRemovalPreparer().prepare(covered)
        XCTAssertTrue(retained.removedItemIDs.isEmpty)
        XCTAssertFalse(retained.libraryChanged)
        XCTAssertEqual(retained.queue?.makeSnapshot(), request.queue?.makeSnapshot())
    }

    private func waitForPreparation(_ preparer: GatedRemovalPreparer) async -> Bool {
        for _ in 0..<10_000 {
            if await preparer.state.isWaiting { return true }
            await Task.yield()
        }
        return false
    }

    private func makeRoot(_ url: URL) -> MediaLibraryRoot {
        MediaLibraryRoot(url: url, displayName: url.lastPathComponent)
    }
}

private final class RemovalAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []
    var started: [URL] { lock.withLock { starts } }
    var stopped: [URL] { lock.withLock { stops } }
    func start(_ url: URL) { lock.withLock { starts.append(url) } }
    func stop(_ url: URL) { lock.withLock { stops.append(url) } }
}

private actor GatedRemovalPreparer: MediaLibraryRemovalPreparing {
    struct State: Sendable {
        var calls = 0
        var didRunOnMainThread = false
        var isWaiting = false
    }
    private(set) var state = State()
    private var gate: CheckedContinuation<Void, Never>?

    func prepare(_ request: MediaLibraryRemovalRequest) async throws -> MediaLibraryRemovalPlan {
        state.calls += 1
        state.didRunOnMainThread = state.didRunOnMainThread || Thread.isMainThread
        if state.calls == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                state.isWaiting = true
            }
        }
        return try await DefaultMediaLibraryRemovalPreparer().prepare(request)
    }

    func release() {
        gate?.resume()
        gate = nil
        state.isWaiting = false
    }
}
