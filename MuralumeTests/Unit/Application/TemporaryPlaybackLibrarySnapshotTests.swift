import Foundation
import XCTest
@testable import Muralume

final class TemporaryPlaybackLibrarySnapshotTests: XCTestCase {
    func testOutsideRequestDoesNotVisitFortyThousandLibraryItems() throws {
        let root = URL(fileURLWithPath: "/tmp/Temporary Large Library")
        let items = (0..<40_000).map { makeItem(root: root, path: "Clip-\($0).mp4") }
        let snapshot = makeSnapshot(items)
        let probe = TemporarySnapshotRootProbe()
        let result = try snapshot.matches(
            canonicalPaths: ["/tmp/Temporary Outside/Clip.mp4"],
            canonicalPath: { probe.resolve($0) }
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertNil(result.items[0])
        XCTAssertEqual(result.visitedItemCount, 0)
        XCTAssertEqual(probe.callCount, 1)
        let existing = try snapshot.matches(
            canonicalPaths: [items[39_999].url.path],
            canonicalPath: { $0.path }
        )
        XCTAssertEqual(existing.items, [items[39_999]])
        XCTAssertEqual(existing.visitedItemCount, 0)
    }

    func testRootsAreReobservedAfterRetargetWithoutRebuildingSnapshot() throws {
        let alias = URL(fileURLWithPath: "/tmp/Temporary Root Alias")
        let item = makeItem(root: alias, path: "Clip.mp4")
        let snapshot = makeSnapshot([item])
        let requested = ["/tmp/Temporary Target A/Clip.mp4", "/tmp/Temporary Target B/Clip.mp4"]
        let first = try snapshot.matches(canonicalPaths: requested) { _ in "/tmp/Temporary Target A" }
        let second = try snapshot.matches(canonicalPaths: requested) { _ in "/tmp/Temporary Target B" }
        XCTAssertEqual(first.items, [item, nil])
        XCTAssertEqual(second.items, [nil, item])
    }

    func testOverlappingAliasRootsUseCurrentLastItemOrder() throws {
        let firstRoot = URL(fileURLWithPath: "/tmp/Temporary Parent Alias")
        let secondRoot = URL(fileURLWithPath: "/tmp/Temporary Child Alias")
        let first = makeItem(root: firstRoot, path: "Nested/Clip.mp4", name: "Parent")
        let second = makeItem(root: secondRoot, path: "Clip.mp4", name: "Child")
        let snapshot = makeSnapshot([first, second])
        let paths = ["/tmp/Temporary Target/Nested/Clip.mp4"]
        let resolve: @Sendable (URL) -> String = { url in
            url == firstRoot ? "/tmp/Temporary Target" : "/tmp/Temporary Target/Nested"
        }
        XCTAssertEqual(try snapshot.matches(canonicalPaths: paths, canonicalPath: resolve).items, [second])
        XCTAssertEqual(try snapshot.reordered(items: [second, first]).matches(
            canonicalPaths: paths, canonicalPath: resolve
        ).items, [first])
        // Reordering does not mutate a previously captured immutable snapshot.
        XCTAssertEqual(try snapshot.matches(canonicalPaths: paths, canonicalPath: resolve).items, [second])
    }

    func testRelativeNormalizationAndMismatchedActualURLMatchOrderedLegacyMap() throws {
        let root = URL(fileURLWithPath: "/tmp/Temporary Lexical Alias")
        let child = URL(fileURLWithPath: "/tmp/Temporary Other Alias")
        let fileRoot = URL(fileURLWithPath: "/tmp/Temporary Single.mp4")
        let items = [
            makeItem(root: root, path: "Folder/./Clip.mp4"),
            makeItem(root: root, path: "Folder/../Normalized.mp4"),
            makeItem(root: root, path: "../Escaped.mp4"),
            makeItem(root: root, path: "../Temporary Lexical Alias/Reentered.mp4"),
            makeItem(root: root, path: "Mismatch.mp4", actualURL: URL(fileURLWithPath: "/tmp/Unrelated.mp4")),
            makeItem(root: root, path: "Café/100% clip.mp4"),
            makeItem(root: child, path: "Clip.mp4"),
            makeItem(root: fileRoot, path: ""),
            makeItem(root: URL(fileURLWithPath: "/"), path: "Root Level.mp4")
        ]
        let roots = [root.path: "/tmp/Temporary Real Target", child.path: "/tmp/Temporary Real Target/Folder"]
        let resolve: @Sendable (URL) -> String = { roots[$0.path] ?? $0.path }
        var expected: [String: LibraryMediaItem] = [:]
        for item in items {
            let canonicalRoot = URL(fileURLWithPath: resolve(item.rootURL)).standardizedFileURL
            let url = item.relativePath.isEmpty ? canonicalRoot
                : canonicalRoot.appendingPathComponent(item.relativePath)
            expected[url.standardizedFileURL.path] = item
        }
        let paths = Array(expected.keys).sorted() + [
            "/tmp/Unrelated.mp4", "/tmp/Temporary Real Target/Folder/../Clip.mp4",
            "/tmp/Temporary Real Target/Cafe\u{301}/100% clip.mp4",
            "/tmp/Temporary Real Target Extra/Mismatch.mp4"
        ]
        XCTAssertEqual(try makeSnapshot(items).matches(
            canonicalPaths: paths, canonicalPath: resolve
        ).items, paths.map { expected[$0] })
    }

    func testDuplicateNormalizedIDsRetainDistinctCanonicalRootSemantics() throws {
        let parent = URL(fileURLWithPath: "/tmp/Temporary Duplicate")
        let child = parent.appendingPathComponent("Nested")
        let first = makeItem(root: parent, path: "Nested/Clip.mp4", name: "Parent")
        let second = makeItem(root: child, path: "Clip.mp4", name: "Child")
        XCTAssertEqual(first.id, second.id)
        let snapshot = makeSnapshot([first, second])
        let paths = ["/tmp/Temporary First/Nested/Clip.mp4", "/tmp/Temporary Second/Clip.mp4"]
        let result = try snapshot.matches(canonicalPaths: paths) { url in
            url == parent ? "/tmp/Temporary First" : "/tmp/Temporary Second"
        }
        XCTAssertEqual(result.items, [first, second])
    }

    func testCancelledAliasLookupDoesNotReturnAPlan() async {
        let first = makeItem(root: URL(fileURLWithPath: "/tmp/Cancelled Alias A"), path: "Clip.mp4")
        let second = makeItem(root: URL(fileURLWithPath: "/tmp/Cancelled Alias B"), path: "Clip.mp4")
        let snapshot = makeSnapshot([first, second])
        let lookup = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try snapshot.matches(canonicalPaths: ["/tmp/Cancelled Target/Clip.mp4"]) { _ in
                "/tmp/Cancelled Target"
            }
        }
        do {
            _ = try await lookup.value
            XCTFail("A cancelled alias lookup must not publish a match")
        } catch is CancellationError {
            // The real worker observes cancellation before returning a plan.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testProductionSessionKeepsLibraryPriorityAndObservedRequestPath() async throws {
        let alias = URL(fileURLWithPath: "/tmp/Temporary Repeated.mp4")
        let root = URL(fileURLWithPath: "/tmp/Temporary Observed")
        let first = makeItem(root: root, path: "A.mp4", actualURL: URL(fileURLWithPath: "/tmp/Actual A.mp4"))
        let second = makeItem(root: root, path: "B.mp4", actualURL: URL(fileURLWithPath: "/tmp/Actual B.mp4"))
        let probe = TemporarySnapshotRetargetProbe(alias: alias)
        let session = TemporaryPlaybackSession(
            scanner: TemporarySnapshotScanner(), canonicalPath: { probe.resolve($0) },
            scopeAccess: .init(startAccess: { _ in false }, stopAccess: { _ in })
        )
        defer { session.end() }
        let result = try await session.resolve(
            [alias, alias, alias], librarySnapshot: makeSnapshot([first, second])
        )
        XCTAssertEqual(result.items, [first, second])
        XCTAssertTrue(result.temporaryItemIDs.isEmpty)
        XCTAssertEqual(result.skippedItemCount, 0)
        XCTAssertEqual(probe.aliasCallCount, 4)
    }

    private func makeSnapshot(_ items: [LibraryMediaItem]) -> TemporaryPlaybackLibrarySnapshot {
        var byID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        var roots: [String: URL] = [:]
        for item in items {
            byID[item.id] = item
            roots[item.id.rootPath] = item.rootURL
        }
        return TemporaryPlaybackLibrarySnapshot(items: items, itemsByID: byID, rootURLsByPath: roots)
    }

    private func makeItem(
        root: URL, path: String, name: String = "Clip", actualURL: URL? = nil
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: root, rootName: "Root", url: actualURL ?? root.appendingPathComponent(path),
            displayName: name, relativePath: path, relativeDirectory: "",
            creationDate: nil, fileSize: 1
        )
    }
}

private final class TemporarySnapshotRootProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.withLock { count } }
    func resolve(_ url: URL) -> String {
        lock.withLock { count += 1 }
        return url.path
    }
}

private final class TemporarySnapshotRetargetProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let alias: URL
    private var count = 0
    init(alias: URL) { self.alias = alias }
    var aliasCallCount: Int { lock.withLock { count } }
    func resolve(_ url: URL) -> String {
        guard url == alias else { return url.path }
        return lock.withLock {
            count += 1
            return count == 2 ? "/tmp/Temporary Observed/B.mp4" : "/tmp/Temporary Observed/A.mp4"
        }
    }
}

private struct TemporarySnapshotScanner: MediaLibraryScanning {
    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        let items = rootURLs.map { url in
            LibraryMediaItem(
                rootURL: url, rootName: "Scanned", kind: .file, url: url,
                displayName: "Scanned", relativePath: "", relativeDirectory: "",
                creationDate: nil, fileSize: 2
            )
        }
        return MediaLibrarySnapshot(roots: [], items: items)
    }
}
