import Foundation
import Darwin
import XCTest
@testable import Muralume

@MainActor
final class SecurityScopedCustomPlaylistMediaAccessTests: XCTestCase {
    func testRestoresFolderGrantWithoutLibraryAndLeaseOutlivesResolver() async throws {
        let fixture = Fixture()
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        var resolution: CustomPlaylistMediaResolution? = await resolver.resolve(
            grants: [fixture.grant], entries: [fixture.entry]
        )
        let item = try XCTUnwrap(resolution?.itemsByEntryID[fixture.entry.id])
        XCTAssertEqual(item.url.path, "/SyntheticPlaylist/clip.mp4")
        XCTAssertNotNil(item.accessLease)
        XCTAssertEqual(resolution?.issuesByEntryID, [:])
        XCTAssertEqual(resolution?.authorizedRootIDs, [.init(standardizedPath: "/SyntheticPlaylist")])
        await resolver.shutdown()
        resolution = nil
        XCTAssertEqual(fixture.state.stops, 0, "The item still owns its independent scope")
        let playbackLease = try MediaPlaybackURLLease(sourceURL: item.url, accessLease: item.accessLease)
        XCTAssertEqual(playbackLease.url, item.url)
        XCTAssertFalse(fixture.state.didRunOnMainThread)
        // The local item and playback lease deliberately retain permission to the end of this test.
    }

    func testSameGrantReusesScopeAndMissingAuthorizationNeverFallsBackToPath() async {
        let fixture = Fixture()
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        _ = await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry])
        _ = await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry])
        XCTAssertEqual(fixture.state.starts, 1)
        let missing = CustomPlaylistEntry(media: fixture.entry.media)
        let unavailable = await resolver.resolve(grants: [], entries: [missing])
        XCTAssertTrue(unavailable.itemsByEntryID.isEmpty)
        XCTAssertEqual(unavailable.issuesByEntryID[missing.id], .authorizationRequired)
        await resolver.shutdown()
        await waitUntil { fixture.state.stops == 1 }
    }

    func testRejectsTraversalSymlinkEscapeAndReportsDefiniteMissingFile() async {
        let fixture = Fixture()
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        let escaped = fixture.entry(path: "../outside.mp4")
        let linked = fixture.entry(path: "link.mp4")
        let missing = fixture.entry(path: "missing.mp4")
        let unsupported = fixture.entry(path: "note.txt")
        let result = await resolver.resolve(
            grants: [fixture.grant], entries: [escaped, linked, missing, unsupported]
        )
        XCTAssertTrue(result.itemsByEntryID.isEmpty)
        XCTAssertEqual(result.issuesByEntryID[escaped.id], .permissionDenied)
        XCTAssertEqual(result.issuesByEntryID[linked.id], .permissionDenied)
        XCTAssertEqual(result.issuesByEntryID[missing.id], .fileMissing)
        XCTAssertEqual(result.issuesByEntryID[unsupported.id], .unsupportedFormat)
        await resolver.shutdown()
        await waitUntil { fixture.state.stops == 1 }
    }

    func testCancellationReturnsWhileBlockedWorkerRetainsPermission() async {
        let fixture = Fixture(blockMetadata: true)
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        let task = Task { await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry]) }
        await waitUntil { fixture.state.didBlock }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.itemsByEntryID.isEmpty)
        await resolver.shutdown()
        XCTAssertEqual(fixture.state.stops, 0)
        fixture.state.unblock()
        await waitUntil { fixture.state.stops == 1 }
        XCTAssertFalse(fixture.state.didRunOnMainThread)
    }

    func testDeadlinePreservesCompletedItemsWhileNativeWorkerRetainsBlockedAccess() async {
        let fixture = Fixture(blockMetadata: true)
        let local = fixture.entry(path: "local.mp4")
        let blocked = fixture.entry(path: "blocked.mp4")
        let state = fixture.state
        let root = fixture.root
        var operations = fixture.operations
        operations.metadata = { url in
            state.recordThread()
            if url == root { return .init(isDirectory: true, isRegularFile: false) }
            if url.lastPathComponent == "blocked.mp4" { state.blockIfRequested() }
            return .init(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 100)
        }
        let resolver = SecurityScopedCustomPlaylistMediaAccess(
            operations: operations, deadline: .milliseconds(250)
        )
        var task: Task<CustomPlaylistMediaResolution, Never>? = Task {
            await resolver.resolve(grants: [fixture.grant], entries: [local, blocked])
        }
        await waitUntil { fixture.state.didBlock }
        var result: CustomPlaylistMediaResolution? = await task?.value
        task = nil

        XCTAssertEqual(result?.itemsByEntryID[local.id]?.url.lastPathComponent, "local.mp4")
        XCTAssertNotNil(result?.itemsByEntryID[local.id]?.accessLease)
        XCTAssertNil(result?.issuesByEntryID[local.id])
        XCTAssertNil(result?.itemsByEntryID[blocked.id])
        XCTAssertEqual(result?.issuesByEntryID[blocked.id], .temporarilyUnavailable)
        XCTAssertEqual(result?.authorizedRootIDs, [.init(standardizedPath: fixture.root.path)])
        XCTAssertEqual(fixture.state.starts, 1)
        XCTAssertEqual(fixture.state.stops, 0)

        // The frozen partial result installs its completed grant in the cache.
        var cached: CustomPlaylistMediaResolution? = await resolver.resolve(grants: [fixture.grant], entries: [local])
        XCTAssertNotNil(cached?.itemsByEntryID[local.id])
        XCTAssertEqual(fixture.state.starts, 1)
        await resolver.shutdown()
        XCTAssertEqual(fixture.state.stops, 0, "The actual blocked worker and returned items still own permission")
        fixture.state.unblock()
        await waitUntil { fixture.state.blockedCount == 0 }
        XCTAssertNil(result?.itemsByEntryID[blocked.id], "Late native completion cannot change the frozen snapshot")
        result = nil
        cached = nil
        await waitUntil { fixture.state.stops == 1 }
        XCTAssertFalse(fixture.state.didRunOnMainThread)
    }

    func testExplicitAuthorizationPreservesGrantIDAndConsumesIncomingScope() async throws {
        let fixture = Fixture()
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        let id = UUID()
        let grant = await resolver.authorize(
            selectedURL: fixture.root, sourcePath: fixture.root.path, kind: .folder, grantID: id
        )
        XCTAssertEqual(grant?.id, id)
        XCTAssertEqual(grant?.bookmark, Data([2]))
        XCTAssertEqual(fixture.state.starts, 0, "The picker already owns its incoming grant")
        await waitUntil { fixture.state.stops == 1 }
        await resolver.shutdown()
        XCTAssertFalse(fixture.state.didRunOnMainThread)
    }

    func testRepeatedUpdatesCannotBypassTwoBlockedNativeWorkers() async {
        let fixture = Fixture(blockMetadata: true)
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: fixture.operations)
        let first = Task { await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry]) }
        await waitUntil { fixture.state.blockedCount == 1 }
        let second = Task { await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry]) }
        await waitUntil { fixture.state.blockedCount == 2 }
        var requests: [Task<CustomPlaylistMediaResolution, Never>] = [first, second]
        for _ in 0..<24 {
            requests.append(Task { await resolver.resolve(grants: [fixture.grant], entries: [fixture.entry]) })
            await Task.yield()
        }
        await waitUntil { fixture.state.blockedCount == 2 }
        XCTAssertEqual(fixture.state.starts, 2)
        XCTAssertEqual(fixture.state.maximumBlocked, 2)
        await resolver.shutdown()
        for request in requests { _ = await request.value }
        fixture.state.unblock()
        fixture.state.unblock()
        await waitUntil { fixture.state.stops == 2 }
    }

    func testMovedRootPathSurvivesRepeatedResolutionAndPersistence() async throws {
        try await verifyMovedRoot(reauthorize: false)
    }

    func testReauthorizedRootPathSurvivesRepeatedResolutionAndPersistence() async throws {
        try await verifyMovedRoot(reauthorize: true)
    }

    private func verifyMovedRoot(reauthorize: Bool) async throws {
        let fixture = Fixture()
        let movedRoot = URL(fileURLWithPath: "/SyntheticMovedPlaylist")
        var operations = fixture.operations
        operations.resolve = { _ in .init(url: movedRoot) }
        operations.metadata = { url in
            url == movedRoot ? .init(isDirectory: true, isRegularFile: false)
                : .init(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 100)
        }
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: operations)
        let grant: CustomPlaylistMediaGrant
        if reauthorize {
            let selected = await resolver.authorize(
                selectedURL: movedRoot, sourcePath: fixture.root.path, kind: .folder, grantID: fixture.grant.id
            )
            grant = try XCTUnwrap(selected)
        } else { grant = fixture.grant }
        let first = await resolver.resolve(grants: [grant], entries: [fixture.entry])
        let refreshed = try XCTUnwrap(first.refreshedGrants.first)
        XCTAssertEqual(refreshed.id, fixture.grant.id)
        XCTAssertEqual(refreshed.sourcePath, movedRoot.path)
        XCTAssertEqual(refreshed.bookmark, grant.bookmark, "An unstale bookmark need not be recreated")
        XCTAssertEqual(first.itemsByEntryID[fixture.entry.id]?.url, movedRoot.appendingPathComponent("clip.mp4"))

        let now = Date(timeIntervalSince1970: 1)
        var collection = CustomPlaylistCollection(playlists: [CustomPlaylist(
            name: "Moved root", entries: [fixture.entry], createdAt: now, updatedAt: now
        )], accessGrants: [grant])
        XCTAssertTrue(try collection.applyMediaResolution(first))
        XCTAssertEqual(collection.accessGrants.first?.id, fixture.grant.id)
        XCTAssertEqual(collection.playlists[0].entries[0].accessGrantID, fixture.grant.id)
        let second = await resolver.resolve(grants: collection.accessGrants, entries: collection.playlists[0].entries)
        XCTAssertNotNil(second.itemsByEntryID[fixture.entry.id])
        XCTAssertTrue(second.refreshedGrants.isEmpty)
        XCTAssertEqual(fixture.state.starts, 1, "The updated grant should reuse the already opened scope")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("playlists.json")
        try await FileCustomPlaylistStore(fileURL: fileURL).save(collection)
        let restored = try await FileCustomPlaylistStore(fileURL: fileURL).load()
        let coldResolver = SecurityScopedCustomPlaylistMediaAccess(operations: operations)
        let cold = await coldResolver.resolve(grants: restored.accessGrants, entries: restored.playlists[0].entries)
        XCTAssertEqual(cold.itemsByEntryID[fixture.entry.id]?.url, movedRoot.appendingPathComponent("clip.mp4"))
        XCTAssertTrue(cold.refreshedGrants.isEmpty)
        await resolver.shutdown()
        await coldResolver.shutdown()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the real playlist worker to finish")
    }

    private struct Fixture {
        let root = URL(fileURLWithPath: "/SyntheticPlaylist")
        let grant: CustomPlaylistMediaGrant
        let state: AccessState

        init(blockMetadata: Bool = false) {
            grant = CustomPlaylistMediaGrant(sourcePath: "/SyntheticPlaylist", kind: .folder, bookmark: Data([1]))
            state = AccessState(blockMetadata: blockMetadata)
        }
        var entry: CustomPlaylistEntry { entry(path: "clip.mp4", id: Self.entryID) }
        private static let entryID = CustomPlaylistEntry.ID()
        func entry(path: String, id: CustomPlaylistEntry.ID = .init()) -> CustomPlaylistEntry {
            let item = LibraryMediaItem(
                rootURL: root, rootName: "Synthetic", url: root.appendingPathComponent(path),
                displayName: path, relativePath: path, relativeDirectory: "", creationDate: nil, fileSize: 1
            )
            return CustomPlaylistEntry(id: id, media: MediaReference(item: item), accessGrantID: grant.id)
        }
        var operations: CustomPlaylistBookmarkOperations {
            let state = state
            let root = root
            return CustomPlaylistBookmarkOperations(
                resolve: { _ in state.recordThread(); return .init(url: root) },
                startAccess: { _ in state.didStart(); return true },
                stopAccess: { _ in state.didStop() },
                makeBookmark: { _ in state.recordThread(); return Data([2]) },
                metadata: { url in
                    state.recordThread()
                    if url == root { return .init(isDirectory: true, isRegularFile: false) }
                    if url.lastPathComponent == "missing.mp4" {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    state.blockIfRequested()
                    return .init(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 100)
                },
                canonicalURL: { url in
                    state.recordThread()
                    return url.lastPathComponent == "link.mp4"
                        ? URL(fileURLWithPath: "/Outside/clip.mp4") : url
                }
            )
        }
    }
}

private final class AccessState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockMetadata: Bool
    private var startCount = 0
    private var stopCount = 0
    private var blocked = false
    private var activeBlocked = 0
    private var maximumBlockedCount = 0
    private var mainThread = false
    init(blockMetadata: Bool) { self.blockMetadata = blockMetadata }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var didBlock: Bool { lock.withLock { blocked } }
    var blockedCount: Int { lock.withLock { activeBlocked } }
    var maximumBlocked: Int { lock.withLock { maximumBlockedCount } }
    var didRunOnMainThread: Bool { lock.withLock { mainThread } }
    func recordThread() { lock.withLock { mainThread = mainThread || Thread.isMainThread } }
    func didStart() { lock.withLock { startCount += 1; mainThread = mainThread || Thread.isMainThread } }
    func didStop() { lock.withLock { stopCount += 1; mainThread = mainThread || Thread.isMainThread } }
    func blockIfRequested() {
        guard blockMetadata else { return }
        lock.withLock {
            blocked = true
            activeBlocked += 1
            maximumBlockedCount = max(maximumBlockedCount, activeBlocked)
        }
        semaphore.wait()
        lock.withLock { activeBlocked -= 1 }
    }
    func unblock() { semaphore.signal() }
}
