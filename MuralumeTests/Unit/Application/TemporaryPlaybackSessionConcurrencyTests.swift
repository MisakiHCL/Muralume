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

    func testLargeInputPreservesExactTailCountsWithBoundedScratch()
        async throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanner = TemporaryPlaybackGatedScanner(blockFirstScan: false)
        let probe = TemporaryPlaybackCanonicalPathProbe()
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { probe.resolve($0) },
            scopeAccess: .init(startAccess: { _ in false }, stopAccess: { _ in }),
            inputPreparationTemporaryDirectoryURL: directory
        )
        defer { session.end() }
        let unique = (0..<5_000).map { mediaURL("Clip-\($0)") }
        let aliases = (1_000..<2_000).map { mediaURL("Clip-\($0)-alias") }
        let unsupported = URL(fileURLWithPath: "/tmp/Unsupported.txt")
        let nonFile = URL(string: "https://example.invalid/a.mp4")!
        let urls = unique + Array(repeating: unique, count: 4).flatMap { $0 }
            + aliases + [unsupported, unsupported, nonFile, nonFile]
        let result = try await session.resolve(urls, libraryItems: [])
        let limit = MediaImportPolicy.maximumTopLevelSourceCount
        XCTAssertEqual(result.items.map(\.url), Array(unique.prefix(limit)))
        XCTAssertEqual(result.skippedItemCount, unique.count - limit + 4)
        // Every occurrence is observed, including the tail, because symlinks
        // can change during the request. Only canonical keys are deduplicated.
        // Accepted files are also resolved once by the scanner matcher.
        XCTAssertEqual(probe.callCount(for: unique[0]), 6)
        XCTAssertEqual(probe.callCount(for: unique[4_000]), 5)
        XCTAssertEqual(probe.callCount(for: aliases[0]), 1)
        XCTAssertEqual(probe.totalCallCount, unique.count * 5 + aliases.count + limit)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertFalse(probe.usedMainThread)
    }

    func testRepeatedURLRetargetingDuringPreparationMatchesLegacyNormalization()
        async throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repeatedURL = mediaURL("Retargeting")
        let otherURLs = (0..<600).map { mediaURL("Other-\($0)") }
        let input = Array(repeating: repeatedURL, count: 4)
            + otherURLs + Array(repeating: repeatedURL, count: 2)
        let legacyResolver = TemporaryPlaybackRetargetingPathProbe(url: repeatedURL)
        var legacyPaths: Set<String> = []
        var legacyAcceptedURLs: [URL] = []
        var legacySkippedCount = 0
        for url in input {
            guard legacyPaths.insert(legacyResolver.resolve(url)).inserted else { continue }
            if legacyAcceptedURLs.count < MediaImportPolicy.maximumTopLevelSourceCount {
                legacyAcceptedURLs.append(url)
            } else {
                legacySkippedCount += 1
            }
        }
        let resolver = TemporaryPlaybackRetargetingPathProbe(url: repeatedURL)
        let scanner = TemporaryPlaybackGatedScanner(blockFirstScan: false, emitsItems: false)
        let session = TemporaryPlaybackSession(
            scanner: scanner, canonicalPath: { resolver.resolve($0) },
            scopeAccess: .init(startAccess: { _ in false }, stopAccess: { _ in }),
            inputPreparationTemporaryDirectoryURL: directory
        )
        defer { session.end() }
        let result = try await session.resolve(input, libraryItems: [])
        // The same URL first resolves to A, then B; both must retain their
        // original input positions, even though the lexical URL is identical.
        XCTAssertEqual(Array(legacyAcceptedURLs.prefix(2)), [repeatedURL, repeatedURL])
        XCTAssertEqual(scanner.requestedURLs, [legacyAcceptedURLs])
        XCTAssertEqual(result.skippedItemCount, legacySkippedCount + legacyAcceptedURLs.count)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancelledSpilledNormalizationKeepsWorkerScopeAndCleansScratch()
        async throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanner = TemporaryPlaybackGatedScanner(blockFirstScan: false)
        let scopes = TemporaryPlaybackScopeProbe()
        let blockedURL = mediaURL("BlockedAfterSpill")
        let canonicalizer = TemporaryPlaybackLibraryRootGate(rootURL: blockedURL)
        let rootURL = URL(fileURLWithPath: "/tmp/Library Scope", isDirectory: true)
        let session = TemporaryPlaybackSession(
            scanner: scanner,
            canonicalPath: { canonicalizer.resolve($0) },
            scopeAccess: scopes.access,
            inputPreparationTemporaryDirectoryURL: directory
        )
        defer { canonicalizer.release(); session.end() }
        let urls = (0..<2_000).map { mediaURL("Clip-\($0)") }
        // Use a distinct last path as the blocking point after the disk spill.
        let input = urls + [blockedURL]
        let resolution = Task {
            try await session.resolve(
                input, libraryItems: [], librarySourceURLs: [rootURL]
            )
        }
        await waitUntil { canonicalizer.didBeginBlockedResolution }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        session.end()
        await assertCancelled(resolution)
        XCTAssertEqual(scopes.startedURLs, [rootURL])
        XCTAssertTrue(scopes.stoppedURLs.isEmpty)
        let latestURL = mediaURL("Latest")
        let latest = Task { try await session.resolve([latestURL], libraryItems: []) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(scanner.callCount, 0)
        canonicalizer.release()
        let result = try await latest.value
        XCTAssertEqual(result.items.map(\.url), [latestURL])
        XCTAssertEqual(scanner.callCount, 1)
        XCTAssertTrue(scopes.stoppedURLs.contains(rootURL))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func makeScratchParent() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Muralume-InputPreparationTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
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
    private let emitsItems: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var wasReleased = false
    private var calls: [[URL]] = []
    private var activeScanCount = 0
    private var peak = 0

    init(blockFirstScan: Bool = true, emitsItems: Bool = true) {
        self.blockFirstScan = blockFirstScan
        self.emitsItems = emitsItems
    }
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
        guard emitsItems else { return MediaLibrarySnapshot(roots: [], items: []) }
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

private final class TemporaryPlaybackRetargetingPathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var callCount = 0

    init(url: URL) { self.url = url }

    func resolve(_ requestedURL: URL) -> String {
        guard requestedURL == url else { return requestedURL.standardizedFileURL.path }
        return lock.withLock {
            let targets = ["A", "B", "A", "B", "Overflow", "Overflow"]
            let target = targets[min(callCount, targets.count - 1)]
            callCount += 1
            return "/tmp/Muralume Canonical Targets/\(target).mp4"
        }
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
    private var calls: [String: Int] = [:]
    var usedMainThread: Bool { lock.withLock { mainThread } }
    var totalCallCount: Int { lock.withLock { calls.values.reduce(0, +) } }
    func callCount(for url: URL) -> Int {
        lock.withLock { calls[url.standardizedFileURL.path, default: 0] }
    }
    func resolve(_ url: URL) -> String {
        lock.withLock {
            mainThread = mainThread || Thread.isMainThread
            calls[url.standardizedFileURL.path, default: 0] += 1
        }
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
