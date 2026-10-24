import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaLibraryCanonicalLookupTests: XCTestCase {
    func testMissAndWarmRootRevalidationRunOffMainAndExactLookupDoesNoIO() async {
        let root = URL(fileURLWithPath: "/tmp/Background Canonical Lookup")
        let item = makeItem(rootURL: root, name: "First", path: "First.mp4")
        let probe = CanonicalPathThreadProbe()
        let fixture = makeFixture(
            selectedURLs: [root],
            snapshot: .init(roots: [.init(url: root, displayName: "Root")], items: [item]),
            canonicalLookup: .init(resolve: { URL(fileURLWithPath: probe.resolve($0)) })
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let outside = root.appendingPathComponent("Missing.mp4")
        let first = await fixture.coordinator.libraryItem(matching: outside)
        XCTAssertNil(first)
        let firstCount = probe.callCount
        XCTAssertEqual(firstCount, 2)
        let second = await fixture.coordinator.libraryItem(matching: outside)
        XCTAssertNil(second)
        XCTAssertEqual(probe.callCount, firstCount + 2)
        XCTAssertEqual(fixture.coordinator.canonicalItemLookupIndexBuildCountForTesting, 1)
        let exact = await fixture.coordinator.libraryItem(matching: item.url)
        XCTAssertEqual(exact, item)
        XCTAssertEqual(probe.callCount, firstCount + 2)
        XCTAssertFalse(probe.didRunOnMainThread)
        await fixture.coordinator.shutdown()
    }

    func testCancelledLookupRetainsItsActualWorkerAndIndependentScopes() async {
        let root = URL(fileURLWithPath: "/tmp/Blocked Canonical Lookup")
        let item = makeItem(rootURL: root, name: "First", path: "First.mp4")
        let probe = CanonicalPathThreadProbe(blockingCallNumber: 1)
        let scopes = CanonicalLookupScopeProbe()
        let fixture = makeFixture(
            selectedURLs: [root],
            snapshot: .init(roots: [.init(url: root, displayName: "Root")], items: [item]),
            canonicalLookup: .init(
                resolve: { URL(fileURLWithPath: probe.resolve($0)) },
                scopeAccess: .init(startAccess: { scopes.start($0) }, stopAccess: { scopes.stop($0) })
            )
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        defer { probe.finishBlockedCall() }
        let outside = root.appendingPathComponent("Missing.mp4")
        let first = Task { await fixture.coordinator.libraryItem(matching: outside) }
        await waitUntil { probe.didBeginBlockedCall }
        XCTAssertFalse(probe.didRunOnMainThread)
        XCTAssertGreaterThan(scopes.startedCount, 0)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(scopes.stoppedCount, 0)
        let second = Task { await fixture.coordinator.libraryItem(matching: outside) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.callCount, 1)
        // Source shutdown cannot close the worker's independent claims.
        await fixture.coordinator.shutdown()
        XCTAssertEqual(scopes.stoppedCount, 0)
        second.cancel()
        _ = await second.value
        probe.finishBlockedCall()
        await waitUntil { scopes.stoppedCount == scopes.startedCount }
        XCTAssertTrue(scopes.startedURLs.contains(root))
    }

    func testLookupRejectsStaleLibrarySnapshotAndRetriesCurrentContent() async {
        let root = URL(fileURLWithPath: "/tmp/Changing Canonical Lookup")
        let first = makeItem(rootURL: root, name: "First", path: "First.mp4")
        let added = makeItem(rootURL: root, name: "Added", path: "Added.mp4")
        let libraryRoot = MediaLibraryRoot(url: root, displayName: "Root")
        let probe = CanonicalPathThreadProbe(blockingCallNumber: 1)
        let fixture = makeFixture(
            selectedURLs: [root], snapshot: .init(roots: [libraryRoot], items: [first]),
            canonicalLookup: .init(resolve: { URL(fileURLWithPath: probe.resolve($0)) })
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        defer { probe.finishBlockedCall() }
        let lookup = Task { await fixture.coordinator.libraryItem(matching: added.url) }
        await waitUntil { probe.didBeginBlockedCall }
        fixture.scanner.enqueueSnapshot(.init(roots: [libraryRoot], items: [first, added]))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        probe.finishBlockedCall()
        let result = await lookup.value
        XCTAssertEqual(result, added)
        XCTAssertEqual(fixture.coordinator.canonicalItemLookupIndexBuildCountForTesting, 0)
        await fixture.coordinator.shutdown()
    }

    func testPublishedDictionarySnapshotTracksContentAndSurvivesSortWithoutMutation() async {
        let root = URL(fileURLWithPath: "/tmp/Shared Layout Lookup")
        let first = makeItem(rootURL: root, name: "A", path: "A.mp4")
        let second = makeItem(rootURL: root, name: "B", path: "B.mp4")
        let libraryRoot = MediaLibraryRoot(url: root, displayName: "Root")
        let fixture = makeFixture(
            selectedURLs: [root], snapshot: .init(roots: [libraryRoot], items: [first])
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        let original = fixture.coordinator.libraryItemsByID
        let contentRevision = fixture.coordinator.itemsContentRevision
        fixture.coordinator.toggleSortDirection()
        XCTAssertEqual(fixture.coordinator.libraryItemsByID, original)
        XCTAssertEqual(fixture.coordinator.itemsContentRevision, contentRevision)
        fixture.scanner.enqueueSnapshot(.init(roots: [libraryRoot], items: [first, second]))
        fixture.coordinator.refresh()
        await waitForScan(fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.libraryItemsByID[second.id], second)
        XCTAssertNil(original[second.id])
        await fixture.coordinator.shutdown()
        XCTAssertTrue(fixture.coordinator.libraryItemsByID.isEmpty)
    }

    func testAliasTieUsesLatestVisibleOrderAfterLookupSuspends() async {
        let firstRoot = URL(fileURLWithPath: "/tmp/Canonical Alias A")
        let secondRoot = URL(fileURLWithPath: "/tmp/Canonical Alias B")
        let target = URL(fileURLWithPath: "/tmp/Canonical Alias Target")
        let first = makeItem(rootURL: firstRoot, name: "A", path: "Clip.mp4")
        let second = makeItem(rootURL: secondRoot, name: "B", path: "Clip.mp4")
        let probe = CanonicalPathThreadProbe(blockingCallNumber: 1)
        let fixture = makeFixture(
            selectedURLs: [firstRoot, secondRoot],
            snapshot: .init(
                roots: [.init(url: firstRoot, displayName: "A"), .init(url: secondRoot, displayName: "B")],
                items: [first, second]
            ),
            canonicalLookup: .init(resolve: { url in
                _ = probe.resolve(url)
                return url == firstRoot || url == secondRoot ? target : url.standardizedFileURL
            })
        )
        fixture.coordinator.addMedia()
        await waitForScan(fixture.coordinator)
        defer { probe.finishBlockedCall() }
        let lookup = Task { await fixture.coordinator.libraryItem(matching: target.appendingPathComponent("Clip.mp4")) }
        await waitUntil { probe.didBeginBlockedCall }
        fixture.coordinator.toggleSortDirection()
        XCTAssertEqual(fixture.coordinator.items.last, first)
        probe.finishBlockedCall()
        let result = await lookup.value
        XCTAssertEqual(result, first)
        await fixture.coordinator.shutdown()
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate())
    }
}

private final class CanonicalLookupScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops = 0
    var startedCount: Int { lock.withLock { starts.count } }
    var stoppedCount: Int { lock.withLock { stops } }
    var startedURLs: [URL] { lock.withLock { starts } }
    func start(_ url: URL) -> Bool { lock.withLock { starts.append(url) }; return true }
    func stop(_ url: URL) { lock.withLock { stops += 1 } }
}
