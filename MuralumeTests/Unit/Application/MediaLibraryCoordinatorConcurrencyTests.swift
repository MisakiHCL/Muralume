import Combine
import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryCoordinatorConcurrencyTests: XCTestCase {
    private enum TestPolicy {
        static let propagationAttempts = 10_000
        static let largeItemCount = 10_000
        static let backgroundSortItemCount = 600
    }

    func testRefreshDoesNotPoisonActiveSearchProjectionCache() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Search Refresh Library")
        let root = makeRoot(rootURL)
        let existingItem = makeItem(
            rootURL: rootURL,
            name: "Existing",
            path: "Existing.mov"
        )
        let addedItem = makeItem(
            rootURL: rootURL,
            name: "Northern Sky",
            path: "Northern Sky.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [existingItem]
            )
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)

        let query = "northern sky"
        let cache = MediaLibrarySearchProjectionCache()
        XCTAssertTrue(
            cache.projection(
                query: query,
                itemsRevision: fixture.coordinator.itemsRevision,
                items: fixture.coordinator.items
            ).items.isEmpty
        )

        // SwiftUI observes objectWillChange synchronously. Recompute here to
        // catch any transient mismatch between the collection and its cache
        // revision during @Published's will-set notification.
        let observation = fixture.coordinator.objectWillChange.sink {
            _ = cache.projection(
                query: query,
                itemsRevision: fixture.coordinator.itemsRevision,
                items: fixture.coordinator.items
            )
        }

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [existingItem, addedItem]
            )
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertTrue(fixture.coordinator.items.contains(addedItem))
        XCTAssertEqual(
            cache.projection(
                query: query,
                itemsRevision: fixture.coordinator.itemsRevision,
                items: fixture.coordinator.items
            ).items,
            [addedItem]
        )
        withExtendedLifetime(observation) {}
        await fixture.coordinator.shutdown()
    }

    func testLargeSortRequestsAreAsynchronousAndLatestRequestWins() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Large Sort Library")
        let root = makeRoot(rootURL)
        let items = makeItems(
            count: TestPolicy.largeItemCount,
            rootURL: rootURL
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: items),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let initialRevision = fixture.coordinator.itemsRevision

        await preparer.blockNext(.sort, count: 2)
        fixture.coordinator.setSortField(.fileSize)
        guard await waitForCall(preparer, stage: .sort, count: 1) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        XCTAssertEqual(fixture.coordinator.itemsRevision, initialRevision)
        fixture.coordinator.setSortDirection(.descending)
        await drainTaskTurns()
        let callsBeforeFirstRelease = await preparer.callCount(for: .sort)
        XCTAssertEqual(callsBeforeFirstRelease, 1)

        let didReleaseFirst = await preparer.release(.sort, call: 1)
        XCTAssertTrue(didReleaseFirst)
        guard await waitForCall(preparer, stage: .sort, count: 2) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        // The canceled worker deliberately returns a value. It still must not
        // publish before the latest, strictly serialized request completes.
        XCTAssertEqual(fixture.coordinator.itemsRevision, initialRevision)
        let didReleaseSecond = await preparer.release(.sort, call: 2)
        XCTAssertTrue(didReleaseSecond)
        let didCommitLatestSort = await waitUntil(
            "latest background sort commit"
        ) {
            fixture.coordinator.items.first?.fileSize
                == Int64(TestPolicy.largeItemCount - 1)
                && fixture.coordinator.items.last?.fileSize == 0
        }
        guard didCommitLatestSort else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        XCTAssertEqual(
            fixture.coordinator.sort,
            MediaLibrarySort(field: .fileSize, direction: .descending)
        )
        XCTAssertEqual(
            fixture.coordinator.itemsRevision,
            initialRevision + 1
        )
        await fixture.coordinator.shutdown()
    }

    func testIdenticalRefreshDoesNotAdvanceItemsRevision() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Identical Refresh Library")
        let root = makeRoot(rootURL)
        let items = [
            makeItem(
                rootURL: rootURL,
                name: "Alpha",
                path: "Alpha.mov",
                fileSize: 1
            ),
            makeItem(
                rootURL: rootURL,
                name: "Bravo",
                path: "Bravo.mov",
                fileSize: 2
            )
        ]
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: items),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let initialItems = fixture.coordinator.items
        let initialRevision = fixture.coordinator.itemsRevision

        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.items, initialItems)
        XCTAssertEqual(fixture.coordinator.itemsRevision, initialRevision)
        await fixture.coordinator.shutdown()
    }

    func testMetadataRefreshAdvancesItemsRevisionForSameID() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Metadata Refresh Library")
        let root = makeRoot(rootURL)
        let original = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov",
            fileSize: 1
        )
        let updated = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov",
            fileSize: 42
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [original]
            ),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let initialRevision = fixture.coordinator.itemsRevision
        XCTAssertEqual(original.id, updated.id)

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(roots: [root], items: [updated])
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.items.first?.id, original.id)
        XCTAssertEqual(fixture.coordinator.items.first?.fileSize, 42)
        XCTAssertEqual(
            fixture.coordinator.itemsRevision,
            initialRevision + 1
        )
        await fixture.coordinator.shutdown()
    }

    func testScanCommitWinsOverStaleSortResult() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Scan Sort Race Library")
        let root = makeRoot(rootURL)
        let items = makeItems(
            count: TestPolicy.backgroundSortItemCount,
            rootURL: rootURL
        )
        let added = makeItem(
            rootURL: rootURL,
            name: "New Scan Result",
            path: "New Scan Result.mov",
            fileSize: 10_000
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: items),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        await preparer.blockNext(.sort)
        fixture.coordinator.setSortField(.fileSize)
        guard await waitForCall(preparer, stage: .sort, count: 1) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(roots: [root], items: items + [added])
        )
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        let scanRevision = fixture.coordinator.itemsRevision
        XCTAssertEqual(fixture.coordinator.items.count, items.count + 1)
        XCTAssertEqual(fixture.coordinator.items.last?.id, added.id)

        let didReleaseSort = await preparer.release(.sort, call: 1)
        XCTAssertTrue(didReleaseSort)
        guard await waitForCompletion(
            preparer,
            stage: .sort,
            count: 1
        ) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }
        await drainTaskTurns()

        XCTAssertEqual(fixture.coordinator.items.count, items.count + 1)
        XCTAssertEqual(fixture.coordinator.items.last?.id, added.id)
        XCTAssertEqual(fixture.coordinator.itemsRevision, scanRevision)
        await fixture.coordinator.shutdown()
    }

    func testScanPreparationRetriesWhenSortChanges() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Scan Prepare Sort Library")
        let root = makeRoot(rootURL)
        let alpha = makeItem(
            rootURL: rootURL,
            name: "Alpha",
            path: "Alpha.mov",
            fileSize: 30
        )
        let bravo = makeItem(
            rootURL: rootURL,
            name: "Bravo",
            path: "Bravo.mov",
            fileSize: 10
        )
        let charlie = makeItem(
            rootURL: rootURL,
            name: "Charlie",
            path: "Charlie.mov",
            fileSize: 20
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [root],
                items: [alpha, bravo]
            ),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let baselinePrepareCalls = await preparer.callCount(for: .prepare)
        await preparer.blockNext(.prepare)
        fixture.scanner.enqueueSnapshot(
            MediaLibrarySnapshot(
                roots: [root],
                items: [alpha, bravo, charlie]
            )
        )
        fixture.coordinator.refresh()
        guard await waitForCall(
            preparer,
            stage: .prepare,
            count: baselinePrepareCalls + 1
        ) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        fixture.coordinator.setSortField(.fileSize)
        let didReleasePrepare = await preparer.release(
            .prepare,
            call: baselinePrepareCalls + 1
        )
        XCTAssertTrue(didReleasePrepare)
        await waitForScan(fixture.coordinator)

        let finalPrepareCalls = await preparer.callCount(for: .prepare)
        XCTAssertGreaterThanOrEqual(
            finalPrepareCalls,
            baselinePrepareCalls + 2
        )
        XCTAssertEqual(
            fixture.coordinator.items.map(\.fileSize),
            [10, 20, 30]
        )
        XCTAssertEqual(fixture.coordinator.sort.field, .fileSize)
        await fixture.coordinator.shutdown()
    }

    func testShutdownDrainsBlockedSortAndRejectsNewSortRequests() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Shutdown Sort Library")
        let root = makeRoot(rootURL)
        let items = makeItems(
            count: TestPolicy.backgroundSortItemCount,
            rootURL: rootURL
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: items),
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let initialRevision = fixture.coordinator.itemsRevision
        XCTAssertTrue(fixture.coordinator.canRefresh)

        await preparer.blockNext(.sort)
        fixture.coordinator.setSortField(.fileSize)
        guard await waitForCall(preparer, stage: .sort, count: 1) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        let completion = ShutdownCompletionProbe()
        let coordinator = fixture.coordinator
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            completion.isComplete = true
        }
        let didBeginShutdown = await waitUntil("shutdown entry") {
            !fixture.coordinator.canRefresh
        }
        guard didBeginShutdown else {
            await preparer.releaseAll()
            await shutdownTask.value
            return
        }

        // isShutDown is already set (observable through canRefresh), so a
        // completed shutdown here would mean it failed to drain sortTasks.
        XCTAssertFalse(completion.isComplete)
        XCTAssertEqual(fixture.coordinator.itemsRevision, initialRevision)

        fixture.coordinator.setSortField(.creationDate)
        fixture.coordinator.toggleSortDirection()
        await drainTaskTurns()
        let sortCallsDuringShutdown = await preparer.callCount(for: .sort)
        XCTAssertEqual(sortCallsDuringShutdown, 1)
        XCTAssertEqual(
            fixture.coordinator.sort,
            MediaLibrarySort(field: .fileSize, direction: .ascending)
        )
        XCTAssertFalse(completion.isComplete)

        let didReleaseSort = await preparer.release(.sort, call: 1)
        XCTAssertTrue(didReleaseSort)
        await shutdownTask.value

        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(fixture.coordinator.itemsRevision, initialRevision)
        let sortCompletions = await preparer.completionCount(for: .sort)
        XCTAssertEqual(sortCompletions, 1)
    }

    func testRemoveRootAwaitsMediaRemovalHookWithRemovedItemIDs() async {
        let removedRootURL = URL(
            fileURLWithPath: "/tmp/Removal Hook Library"
        )
        let retainedRootURL = URL(
            fileURLWithPath: "/tmp/Retained Hook Library"
        )
        let removedRoot = makeRoot(removedRootURL)
        let retainedRoot = makeRoot(retainedRootURL)
        let removedItem = makeItem(
            rootURL: removedRootURL,
            name: "Removed",
            path: "Removed.mov"
        )
        let retainedItem = makeItem(
            rootURL: retainedRootURL,
            name: "Retained",
            path: "Retained.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [removedRootURL, retainedRootURL],
            snapshot: MediaLibrarySnapshot(
                roots: [removedRoot, retainedRoot],
                items: [removedItem, retainedItem]
            )
        )
        let hook = MediaScopeHookProbe()
        fixture.coordinator.mediaItemsWillBeRemovedHandler = { itemIDs in
            await hook.suspend(itemIDs: itemIDs)
        }

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let removalTask = Task { @MainActor in
            await fixture.coordinator.removeRoot(removedRoot)
        }
        let didReachHook = await waitUntil("media removal hook") {
            hook.isWaiting
        }
        guard didReachHook else {
            hook.release()
            await removalTask.value
            await fixture.coordinator.shutdown()
            return
        }

        XCTAssertEqual(hook.receivedItemIDSets, [[removedItem.id]])
        XCTAssertTrue(fixture.session.removedURLs.isEmpty)

        hook.release()
        await removalTask.value

        XCTAssertEqual(fixture.session.removedURLs, [removedRootURL])
        XCTAssertEqual(fixture.coordinator.items.map(\.id), [retainedItem.id])
        await fixture.coordinator.shutdown()
    }

    func testShutdownAwaitsMediaScopePreparationBeforeStoppingSession() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Shutdown Hook Library")
        let root = makeRoot(rootURL)
        let item = makeItem(
            rootURL: rootURL,
            name: "Clip",
            path: "Clip.mov"
        )
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: MediaLibrarySnapshot(roots: [root], items: [item])
        )
        let hook = MediaScopeHookProbe()
        fixture.coordinator.prepareForMediaScopeShutdownHandler = {
            await hook.suspend()
        }

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let shutdownTask = Task { @MainActor in
            await fixture.coordinator.shutdown()
        }
        let didReachHook = await waitUntil("media scope shutdown hook") {
            hook.isWaiting
        }
        guard didReachHook else {
            hook.release()
            await shutdownTask.value
            return
        }

        XCTAssertEqual(hook.callCount, 1)
        XCTAssertEqual(fixture.session.stopCount, 0)

        hook.release()
        await shutdownTask.value

        XCTAssertEqual(fixture.session.stopCount, 1)
    }

    func testQueueNavigationWinsOverStaleReconciliation() async {
        let rootURL = URL(fileURLWithPath: "/tmp/Queue Revision Library")
        let root = makeRoot(rootURL)
        let first = makeItem(
            rootURL: rootURL,
            name: "Alpha",
            path: "Alpha.mov"
        )
        let second = makeItem(
            rootURL: rootURL,
            name: "Bravo",
            path: "Bravo.mov"
        )
        let third = makeItem(
            rootURL: rootURL,
            name: "Charlie",
            path: "Charlie.mov"
        )
        let snapshot = MediaLibrarySnapshot(
            roots: [root],
            items: [first, second, third]
        )
        let preparer = ControlledMediaLibrarySnapshotPreparer()
        let fixture = makeFixture(
            selectedURLs: [rootURL],
            snapshot: snapshot,
            snapshotPreparer: preparer
        )

        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        fixture.coordinator.play(first)
        await waitForLoads(fixture.engine, count: 1)
        await waitForReady(fixture.playback)

        let baselineReconciliations = await preparer.callCount(
            for: .reconcileQueue
        )
        await preparer.blockNext(.reconcileQueue)
        await preparer.forceQueueReplacementOnNextReconciliation()
        fixture.scanner.enqueueSnapshot(snapshot)
        fixture.coordinator.refresh()
        guard await waitForCall(
            preparer,
            stage: .reconcileQueue,
            count: baselineReconciliations + 1
        ) else {
            await preparer.releaseAll()
            await fixture.coordinator.shutdown()
            return
        }

        let blockedQueueStateRevision =
            fixture.coordinator.queueStateRevision
        XCTAssertTrue(fixture.coordinator.playNext())
        await waitForLoads(fixture.engine, count: 2)
        await waitForReady(fixture.playback)
        let navigatedQueueSnapshot = fixture.coordinator.makeQueueSnapshot()
        let navigatedQueueRevision = fixture.coordinator.queueRevision
        let navigatedQueueStateRevision =
            fixture.coordinator.queueStateRevision
        XCTAssertGreaterThan(
            navigatedQueueStateRevision,
            blockedQueueStateRevision
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)

        let didReleaseReconciliation = await preparer.release(
            .reconcileQueue,
            call: baselineReconciliations + 1
        )
        XCTAssertTrue(didReleaseReconciliation)
        await waitForScan(fixture.coordinator)

        let finalReconciliationCalls = await preparer.callCount(
            for: .reconcileQueue
        )
        XCTAssertGreaterThanOrEqual(
            finalReconciliationCalls,
            baselineReconciliations + 2
        )
        XCTAssertEqual(
            fixture.coordinator.makeQueueSnapshot(),
            navigatedQueueSnapshot
        )
        XCTAssertEqual(fixture.coordinator.currentItemID, second.id)
        XCTAssertEqual(
            fixture.coordinator.queueRevision,
            navigatedQueueRevision
        )
        XCTAssertEqual(
            fixture.coordinator.queueStateRevision,
            navigatedQueueStateRevision
        )
        await fixture.coordinator.shutdown()
    }

    private func makeRoot(_ url: URL) -> MediaLibraryRoot {
        MediaLibraryRoot(
            url: url,
            displayName: url.lastPathComponent
        )
    }

    private func makeItems(
        count: Int,
        rootURL: URL
    ) -> [LibraryMediaItem] {
        precondition(count > 0)
        return (0..<count).map { index in
            let nameRank = (index * 37) % count
            let displayName = String(
                format: "Clip %05d",
                nameRank
            )
            return makeItem(
                rootURL: rootURL,
                name: displayName,
                path: "Item-\(index).mov",
                fileSize: Int64(index)
            )
        }
    }

    private func waitForCall(
        _ preparer: ControlledMediaLibrarySnapshotPreparer,
        stage: ControlledMediaLibrarySnapshotPreparer.Stage,
        count expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<TestPolicy.propagationAttempts {
            let callCount = await preparer.callCount(for: stage)
            if callCount >= expectedCount {
                return true
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(stage) call \(expectedCount)",
            file: file,
            line: line
        )
        return false
    }

    private func waitForCompletion(
        _ preparer: ControlledMediaLibrarySnapshotPreparer,
        stage: ControlledMediaLibrarySnapshotPreparer.Stage,
        count expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<TestPolicy.propagationAttempts {
            let completionCount = await preparer.completionCount(for: stage)
            if completionCount >= expectedCount {
                return true
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(stage) completion \(expectedCount)",
            file: file,
            line: line
        )
        return false
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<TestPolicy.propagationAttempts {
            if condition() {
                return true
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(description)",
            file: file,
            line: line
        )
        return false
    }

    private func drainTaskTurns(_ count: Int = 64) async {
        for _ in 0..<count {
            await Task.yield()
        }
    }
}

@MainActor
private final class ShutdownCompletionProbe {
    var isComplete = false
}

@MainActor
private final class MediaScopeHookProbe {
    private(set) var receivedItemIDSets:
        [Set<LibraryMediaItem.ID>] = []
    private(set) var callCount = 0
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend(itemIDs: Set<LibraryMediaItem.ID>? = nil) async {
        callCount += 1
        if let itemIDs {
            receivedItemIDSets.append(itemIDs)
        }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
