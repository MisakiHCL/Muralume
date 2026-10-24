import XCTest
@testable import Muralume

@MainActor
final class TemporaryPlaybackSessionConcurrencyTests: XCTestCase {
    func testSupersededScansKeepOneRealWorkerAndOnlyLatestQueuedRequest()
        async throws {
        let scanner = TemporaryPlaybackGatedScanner()
        let scopes = TemporaryPlaybackScopeProbe()
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { $0.standardizedFileURL.path },
            scopeAccess: scopes.access
        )
        defer { scanner.releaseFirstScan(); session.end() }
        let firstURL = mediaURL("First")
        let discardedURL = mediaURL("Discarded")
        let latestURL = mediaURL("Latest")
        let first = Task {
            try await session.resolve([firstURL], libraryItems: [])
        }
        await waitUntil { scanner.callCount == 1 }
        let discarded = Task {
            try await session.resolve([discardedURL], libraryItems: [])
        }
        await assertCancelled(first)
        let latest = Task {
            try await session.resolve([latestURL], libraryItems: [])
        }
        await assertCancelled(discarded)
        XCTAssertEqual(scanner.callCount, 1)
        XCTAssertEqual(scanner.peakScanCount, 1)
        XCTAssertEqual(scopes.startedURLs, [firstURL])
        XCTAssertTrue(scopes.stoppedURLs.isEmpty)

        scanner.releaseFirstScan()
        let result = try await latest.value
        XCTAssertEqual(result.items.map(\.url), [latestURL])
        XCTAssertEqual(scanner.requestedURLs, [[firstURL], [latestURL]])
        XCTAssertEqual(scanner.peakScanCount, 1)
        await waitUntil { scopes.stoppedURLs.contains(firstURL) }
        XCTAssertFalse(scopes.stoppedURLs.contains(latestURL))
        session.end()
        XCTAssertEqual(Set(scopes.stoppedURLs), [firstURL, latestURL])
    }

    func testEndingResolutionReturnsWithoutClosingBlockedWorkersScope() async {
        let scanner = TemporaryPlaybackGatedScanner()
        let scopes = TemporaryPlaybackScopeProbe()
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { $0.standardizedFileURL.path },
            scopeAccess: scopes.access
        )
        defer { scanner.releaseFirstScan(); session.end() }
        let url = mediaURL("Ending")
        let resolution = Task {
            try await session.resolve([url], libraryItems: [])
        }
        await waitUntil { scanner.callCount == 1 }
        session.end()
        await assertCancelled(resolution)
        XCTAssertEqual(scanner.callCount, 1)
        XCTAssertTrue(scopes.stoppedURLs.isEmpty)
        scanner.releaseFirstScan()
        await waitUntil { scopes.stoppedURLs == [url] }
    }

    func testCancelledMatcherRetainsIndependentLibraryScopeUntilWorkerExits()
        async {
        let rootURL = URL(fileURLWithPath: "/tmp/Muralume Scoped Library", isDirectory: true)
        let requestedURL = rootURL.appendingPathComponent("Clip.mp4")
        let item = LibraryMediaItem(
            rootURL: rootURL, rootName: "Scoped Library", kind: .folder,
            url: requestedURL, displayName: "Clip",
            relativePath: "Clip.mp4", relativeDirectory: "",
            creationDate: nil, fileSize: 1
        )
        let scanner = TemporaryPlaybackGatedScanner(blockFirstScan: false)
        let scopes = TemporaryPlaybackScopeProbe()
        let canonicalizer = TemporaryPlaybackLibraryRootGate(rootURL: rootURL)
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { canonicalizer.resolve($0) },
            scopeAccess: scopes.access
        )
        defer { canonicalizer.release(); session.end() }
        let resolution = Task {
            try await session.resolve(
                [requestedURL], libraryItems: [item], librarySourceURLs: [rootURL]
            )
        }
        await waitUntil { canonicalizer.didBeginBlockedResolution }
        XCTAssertEqual(scopes.startedURLs, [rootURL, requestedURL])
        session.end()
        await assertCancelled(resolution)
        // The caller and library owner may now shut down. The real matcher
        // still owns a separate claim for the exact scoped library URL.
        XCTAssertTrue(scopes.stoppedURLs.isEmpty)
        canonicalizer.release()
        await waitUntil { scopes.stoppedURLs.count == 2 }
        XCTAssertEqual(Set(scopes.stoppedURLs), [rootURL, requestedURL])
    }

    func testBackgroundInputPreparationPreservesOrderDuplicatesAndSkippedCount()
        async throws {
        let scanner = TemporaryPlaybackGatedScanner(blockFirstScan: false)
        let probe = TemporaryPlaybackCanonicalPathProbe()
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { probe.resolve($0) },
            scopeAccess: .init(startAccess: { _ in false }, stopAccess: { _ in })
        )
        defer { session.end() }
        let acceptedURLs = (0..<MediaImportPolicy.maximumTopLevelSourceCount)
            .map { mediaURL("Clip-\($0)") }
        let overflow = mediaURL("Overflow")
        let urls = [acceptedURLs[0], mediaURL("Clip-0-alias")]
            + Array(acceptedURLs.dropFirst())
            + [overflow, overflow, URL(string: "https://example.invalid/a.mp4")!,
               URL(fileURLWithPath: "/tmp/Unsupported.txt")]
        let result = try await session.resolve(urls, libraryItems: [])
        XCTAssertEqual(result.items.map(\.url), acceptedURLs)
        XCTAssertEqual(result.skippedItemCount, 3)
        XCTAssertEqual(scanner.requestedURLs, [acceptedURLs])
        XCTAssertFalse(probe.usedMainThread)
    }

    private func mediaURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/Muralume Temporary Pipeline/\(name).mp4")
    }

    private func assertCancelled(
        _ task: Task<TemporaryPlaybackResolution, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("A superseded resolution must return promptly", file: file, line: line)
        } catch is CancellationError {
            // Expected even while the real scanner remains blocked.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private final class TemporaryPlaybackGatedScanner:
    MediaLibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let blockFirstScan: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var wasReleased = false
    private var calls: [[URL]] = []
    private var activeScanCount = 0
    private var peak = 0

    init(blockFirstScan: Bool = true) { self.blockFirstScan = blockFirstScan }
    var callCount: Int { lock.withLock { calls.count } }
    var peakScanCount: Int { lock.withLock { peak } }
    var requestedURLs: [[URL]] { lock.withLock { calls } }

    func scan(rootURLs: [URL]) async throws -> MediaLibrarySnapshot {
        try await scan(sources: rootURLs.map { .init(url: $0, kind: .file) })
    }

    func scan(sources: [MediaSource]) async throws -> MediaLibrarySnapshot {
        let shouldBlock = lock.withLock {
            calls.append(sources.map(\.url))
            activeScanCount += 1
            peak = max(peak, activeScanCount)
            return blockFirstScan && calls.count == 1
        }
        defer { lock.withLock { activeScanCount -= 1 } }
        if shouldBlock {
            // Deliberately ignores cancellation until the real work is released.
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if wasReleased { return true }
                    firstContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let items = sources.map { source in
            LibraryMediaItem(
                rootURL: source.url, rootName: source.url.lastPathComponent,
                kind: .file, url: source.url,
                displayName: source.url.lastPathComponent,
                relativePath: "", relativeDirectory: "",
                creationDate: nil, fileSize: 1
            )
        }
        return MediaLibrarySnapshot(roots: [], items: items)
    }

    func releaseFirstScan() {
        let continuation = lock.withLock {
            wasReleased = true
            let continuation = firstContinuation
            firstContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class TemporaryPlaybackScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []
    var startedURLs: [URL] { lock.withLock { started } }
    var stoppedURLs: [URL] { lock.withLock { stopped } }
    var access: TemporaryPlaybackSecurityScopeAccess {
        .init(startAccess: { url in
            self.lock.withLock { self.started.append(url) }
            return true
        }, stopAccess: { url in
            self.lock.withLock { self.stopped.append(url) }
        })
    }
}

private final class TemporaryPlaybackCanonicalPathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThread = false
    var usedMainThread: Bool { lock.withLock { mainThread } }
    func resolve(_ url: URL) -> String {
        lock.withLock { mainThread = mainThread || Thread.isMainThread }
        return url.standardizedFileURL.path.replacingOccurrences(
            of: "-alias.mp4", with: ".mp4"
        )
    }
}

private final class TemporaryPlaybackLibraryRootGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let rootURL: URL
    private var didBlock = false

    init(rootURL: URL) { self.rootURL = rootURL }
    var didBeginBlockedResolution: Bool { lock.withLock { didBlock } }

    func resolve(_ url: URL) -> String {
        let shouldBlock = lock.withLock {
            if url == rootURL, !didBlock {
                didBlock = true
                return true
            }
            return false
        }
        if shouldBlock { gate.wait() }
        return url.standardizedFileURL.path
    }

    func release() { gate.signal() }
}
