import Foundation
import XCTest
@testable import Muralume

@MainActor
final class CustomPlaylistVideoImportTests: XCTestCase {
    func testPickedVideosPersistIndependentGrantsInSelectionOrderWithoutLibraryCapture() async throws {
        let state = PlaylistImportState()
        let importer = CustomPlaylistVideoImporter(executor: executor(state))
        let (controller, store, id) = try await makeController()
        let urls = [video("B"), video("A"), video("B")]

        let added = try await controller.addSelectedVideos(urls, to: id, using: importer)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(controller.collection.playlist(id: id)?.entries.map(\.media.lastKnownDisplayName), ["B", "A"])
        XCTAssertEqual(controller.collection.accessGrants.map(\.kind), [.file, .file])
        XCTAssertEqual(Set(controller.collection.accessGrants.map(\.sourcePath)), Set(urls.map(\.path)))
        XCTAssertTrue(controller.resolutionItems.isEmpty, "Import preparation never invents resolved playable items")
        let persistedSuccessfully = await controller.flushPersistence()
        XCTAssertTrue(persistedSuccessfully)
        let persisted = await store.collection
        XCTAssertEqual(persisted, controller.collection)
        await waitUntil { state.released.count == urls.count }
        XCTAssertEqual(state.inspections, 3)
        XCTAssertEqual(state.bookmarks, 2)
        XCTAssertFalse(state.didInspectOnMainThread)
        await controller.shutdown()
    }

    func testIndependentResolverCanPlayPickedFileWithoutAnyLibrarySource() async throws {
        let state = PlaylistImportState()
        let resolver = SecurityScopedCustomPlaylistMediaAccess(operations: .init(
            resolve: { data in .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self))) },
            startAccess: { _ in true }, stopAccess: { _ in },
            makeBookmark: { Data($0.path.utf8) },
            metadata: { _ in .init(fileSize: 10) }, canonicalURL: { $0.standardizedFileURL }
        ))
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Independent")
        let controller = CustomPlaylistController(store: PlaylistImportStore(collection), resolver: resolver)
        await controller.startAndWait()
        _ = try await controller.addSelectedVideos([video("A")], to: id, using: CustomPlaylistVideoImporter(executor: executor(state)))
        await controller.waitForMediaResolution()
        let item = try XCTUnwrap(controller.resolvedItems(in: id).first)
        XCTAssertEqual(item.url, video("A"))
        XCTAssertNotNil(item.accessLease)
        await controller.shutdown()
    }

    func testUnavailableSelectionIsAtomicAndReleasesEveryIncomingGrant() async throws {
        for rejectedName in ["Missing", "Folder", "Linked", "NoBookmark", "Note"] {
            let state = PlaylistImportState()
            let (controller, _, id) = try await makeController()
            let rejected = rejectedName == "Note" ? URL(fileURLWithPath: "/SyntheticPlaylistImport/Note.txt") : video(rejectedName)
            do {
                _ = try await controller.addSelectedVideos([video("A"), rejected], to: id, using: CustomPlaylistVideoImporter(executor: executor(state)))
                XCTFail("A rejected file must not partially change the playlist")
            } catch {
                XCTAssertEqual(error as? CustomPlaylistVideoImportError, .unavailable)
            }
            XCTAssertTrue(controller.collection.allEntries.isEmpty)
            XCTAssertTrue(controller.collection.accessGrants.isEmpty)
            await waitUntil { state.released.count == 2 }
            await controller.shutdown()
        }
    }

    func testSelectionLimitRejectsWholeTransactionBeforeInspectionAndReleasesExcessScopes() async throws {
        let state = PlaylistImportState()
        let urls = (0...MediaImportPolicy.maximumTopLevelSourceCount).map { video("\($0)") }
        do {
            _ = try await CustomPlaylistVideoImporter(executor: executor(state)).prepare(urls)
            XCTFail("The picker selection limit must be explicit")
        } catch {
            XCTAssertEqual(error as? CustomPlaylistVideoImportError, .selectionLimitReached)
        }
        await waitUntil { state.released.count == urls.count }
        XCTAssertEqual(state.inspections, 0)
        XCTAssertEqual(state.bookmarks, 0)
    }

    func testCancellationDoesNotCommitAndBlockedNativeWorkRetainsItsScopeUntilItReturns() async throws {
        let state = PlaylistImportState(blocksInspection: true)
        let (controller, _, id) = try await makeController()
        let importer = CustomPlaylistVideoImporter(executor: executor(state))
        let task = Task { try await controller.addSelectedVideos([video("A"), video("B")], to: id, using: importer) }
        await waitUntil { state.isBlocked }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import must not commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(controller.collection.allEntries.isEmpty)
        XCTAssertFalse(state.released.contains(video("A")), "The native inspector still needs its incoming permission")
        state.unblock()
        await waitUntil { state.released.count == 2 }
        await controller.shutdown()
    }

    func testDeletingPlaylistDuringPreparationDoesNotResurrectItOrRetainGrants() async throws {
        let state = PlaylistImportState(blocksInspection: true)
        let (controller, _, id) = try await makeController()
        let importer = CustomPlaylistVideoImporter(executor: executor(state))
        let task = Task { try await controller.addSelectedVideos([video("A")], to: id, using: importer) }
        await waitUntil { state.isBlocked }
        try controller.removePlaylist(id: id)
        state.unblock()
        do { _ = try await task.value; XCTFail("A deleted playlist must stay deleted") }
        catch { XCTAssertEqual(error as? CustomPlaylistMutationError, .playlistNotFound) }
        XCTAssertTrue(controller.collection.playlists.isEmpty)
        XCTAssertTrue(controller.collection.accessGrants.isEmpty)
        await waitUntil { state.released.count == 1 }
        await controller.shutdown()
    }

    func testDeadlineReturnsFailureWhileBlockedNativeWorkKeepsItsIncomingPermission() async throws {
        let state = PlaylistImportState(blocksInspection: true)
        let importer = CustomPlaylistVideoImporter(executor: executor(state), deadline: .milliseconds(250))
        let task = Task { try await importer.prepare([video("A")]) }
        await waitUntil { state.isBlocked }
        do { _ = try await task.value; XCTFail("A blocked file must have a bounded import deadline") }
        catch { XCTAssertEqual(error as? CustomPlaylistVideoImportError, .unavailable) }
        XCTAssertTrue(state.released.isEmpty)
        state.unblock()
        await waitUntil { state.released.count == 1 }
    }

    func testEmptyPickerResultDoesNotChangePlaylistOrCapturePermission() async throws {
        let state = PlaylistImportState()
        let (controller, _, id) = try await makeController()
        let before = controller.collectionRevision
        let added = try await controller.addSelectedVideos([], to: id, using: CustomPlaylistVideoImporter(executor: executor(state)))
        XCTAssertEqual(added, 0)
        XCTAssertEqual(controller.collectionRevision, before)
        XCTAssertTrue(state.released.isEmpty)
        XCTAssertEqual(state.inspections, 0)
        await controller.shutdown()
    }

    private func video(_ name: String) -> URL { URL(fileURLWithPath: "/SyntheticPlaylistImport/\(name).mp4") }

    private func makeController() async throws -> (CustomPlaylistController, PlaylistImportStore, CustomPlaylist.ID) {
        var collection = CustomPlaylistCollection.empty
        let id = try collection.createPlaylist(named: "Picked")
        let store = PlaylistImportStore(collection)
        let controller = CustomPlaylistController(store: store)
        await controller.startAndWait()
        return (controller, store, id)
    }

    private func executor(_ state: PlaylistImportState) -> UserSelectedMediaImportExecutor {
        UserSelectedMediaImportExecutor(inspect: { url, _ in
            state.inspect()
            let name = url.deletingPathExtension().lastPathComponent
            return MediaSourceImportInspection(
                kind: name == "Missing" ? nil : (name == "Folder" ? .folder : .file),
                linkResolution: .init(targetURL: url, didResolveLink: name == "Linked"),
                resourceIdentifier: nil, coveredByFolderPaths: [], containsFolderPaths: [], containsFilePaths: []
            )
        }, makeBookmark: { url in
            state.madeBookmark()
            return url.deletingPathExtension().lastPathComponent == "NoBookmark" ? nil : Data(url.path.utf8)
        }, releaseIncomingScope: { state.release($0) })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Expected bounded import state transition", file: file, line: line)
    }
}

private actor PlaylistImportStore: CustomPlaylistStoring {
    private(set) var collection: CustomPlaylistCollection
    init(_ collection: CustomPlaylistCollection) { self.collection = collection }
    func load() async throws -> CustomPlaylistCollection { collection }
    func save(_ collection: CustomPlaylistCollection) async throws { self.collection = collection }
}

private final class PlaylistImportState: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blocksInspection: Bool
    private var storedReleased: [URL] = []
    private var inspectionCount = 0
    private var bookmarkCount = 0
    private var blocked = false
    private var mainThread = false
    init(blocksInspection: Bool = false) { self.blocksInspection = blocksInspection }
    var released: [URL] { lock.withLock { storedReleased } }
    var inspections: Int { lock.withLock { inspectionCount } }
    var bookmarks: Int { lock.withLock { bookmarkCount } }
    var isBlocked: Bool { lock.withLock { blocked } }
    var didInspectOnMainThread: Bool { lock.withLock { mainThread } }
    func inspect() {
        lock.withLock { inspectionCount += 1; mainThread = mainThread || Thread.isMainThread; blocked = blocksInspection }
        if blocksInspection { gate.wait() }
    }
    func madeBookmark() { lock.withLock { bookmarkCount += 1 } }
    func release(_ url: URL) { lock.withLock { storedReleased.append(url) } }
    func unblock() { gate.signal() }
}
