import Foundation

struct TemporaryPlaybackResolution: Sendable {
    let items: [LibraryMediaItem]
    let temporaryItemIDs: Set<LibraryMediaItem.ID>
    let skippedItemCount: Int
}

struct MediaLibraryPlaybackContext: Sendable {
    let queueSnapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let playbackCollection: PlaybackCollection
    let currentTime: TimeInterval
    let playbackIntent: PlaybackIntent
}

private struct TemporaryPlaybackMatchPlan: Sendable {
    let items: [LibraryMediaItem]
    let temporaryItemIDs: Set<LibraryMediaItem.ID>
    let retainsScopeByRequestedFileIndex: [Bool]
}

private struct TemporaryPlaybackMatcher: Sendable {
    typealias CanonicalPathResolver = @Sendable (URL) -> String

    let canonicalPath: CanonicalPathResolver

    func match(
        requestedFiles: [URL],
        requestedCanonicalPaths: [String],
        libraryItems: [LibraryMediaItem],
        scannedItems: [LibraryMediaItem]
    ) throws -> TemporaryPlaybackMatchPlan {
        let libraryItemsByPath = try itemsByCanonicalPath(libraryItems)
        let scannedItemsByPath = try itemsByCanonicalPath(scannedItems)
        var resolvedItems: [LibraryMediaItem] = []
        var temporaryItemIDs: Set<LibraryMediaItem.ID> = []
        var retainsScopeByRequestedFileIndex = Array(
            repeating: false,
            count: requestedFiles.count
        )
        resolvedItems.reserveCapacity(requestedFiles.count)

        for index in requestedFiles.indices {
            try Task.checkCancellation()
            let path = requestedCanonicalPaths[index]
            if let libraryItem = libraryItemsByPath[path] {
                resolvedItems.append(libraryItem)
                continue
            }
            guard let scannedItem = scannedItemsByPath[path] else {
                continue
            }
            resolvedItems.append(scannedItem)
            temporaryItemIDs.insert(scannedItem.id)
            retainsScopeByRequestedFileIndex[index] = true
        }

        return TemporaryPlaybackMatchPlan(
            items: resolvedItems,
            temporaryItemIDs: temporaryItemIDs,
            retainsScopeByRequestedFileIndex:
                retainsScopeByRequestedFileIndex
        )
    }

    private func itemsByCanonicalPath(
        _ items: [LibraryMediaItem]
    ) throws -> [String: LibraryMediaItem] {
        var result: [String: LibraryMediaItem] = [:]
        var canonicalRootURLsByPath: [String: URL] = [:]
        result.reserveCapacity(items.count)
        canonicalRootURLsByPath.reserveCapacity(
            min(items.count, MediaImportPolicy.maximumActiveSourceCount)
        )
        for item in items {
            try Task.checkCancellation()
            let rootPath = item.rootURL.standardizedFileURL.path
            let canonicalRootURL: URL
            if let cachedRootURL = canonicalRootURLsByPath[rootPath] {
                canonicalRootURL = cachedRootURL
            } else {
                canonicalRootURL = URL(
                    fileURLWithPath: canonicalPath(item.rootURL)
                ).standardizedFileURL
                canonicalRootURLsByPath[rootPath] = canonicalRootURL
            }
            let canonicalItemURL = if item.relativePath.isEmpty {
                canonicalRootURL
            } else {
                canonicalRootURL.appendingPathComponent(item.relativePath)
            }
            result[canonicalItemURL.standardizedFileURL.path] = item
        }
        return result
    }
}

struct TemporaryPlaybackSecurityScopeAccess: Sendable {
    let startAccess: @Sendable (URL) -> Bool
    let stopAccess: @Sendable (URL) -> Void

    static let live = TemporaryPlaybackSecurityScopeAccess(
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Retained by the real worker, including after its cancelled caller returns.
private final class TemporaryPlaybackScopeLease: @unchecked Sendable {
    let url: URL
    private let didStart: Bool
    private let access: TemporaryPlaybackSecurityScopeAccess

    init(url: URL, access: TemporaryPlaybackSecurityScopeAccess) {
        self.url = url
        self.access = access
        didStart = access.startAccess(url)
    }

    deinit {
        if didStart { access.stopAccess(url) }
    }
}

@MainActor
final class TemporaryPlaybackSession {
    private struct RequestedFileBatch: Sendable {
        let urls: [URL]
        let canonicalPaths: [String]
        let skippedItemCount: Int
    }

    private struct PreparedResolution: Sendable {
        let resolution: TemporaryPlaybackResolution
        let retainedScopes: [TemporaryPlaybackScopeLease]
    }

    private let scanner: any MediaLibraryScanning
    private let matcher: TemporaryPlaybackMatcher
    private let scopeAccess: TemporaryPlaybackSecurityScopeAccess
    private let workPool = BoundedMediaWorkPool(
        maximumConcurrentWorkCount: 1,
        maximumQueuedWorkCount: 1
    )
    private var activeScopes: [TemporaryPlaybackScopeLease] = []
    private var activeResolutionTask: Task<PreparedResolution, Error>?
    private var resolutionGeneration: UInt64 = 0

    init(
        scanner: any MediaLibraryScanning,
        canonicalPath: @escaping @Sendable (URL) -> String = {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        },
        scopeAccess: TemporaryPlaybackSecurityScopeAccess = .live
    ) {
        self.scanner = scanner
        matcher = TemporaryPlaybackMatcher(canonicalPath: canonicalPath)
        self.scopeAccess = scopeAccess
    }

    deinit { activeResolutionTask?.cancel() }

    func resolve(
        _ requestedURLs: [URL],
        libraryItems: [LibraryMediaItem],
        librarySourceURLs: [URL] = []
    ) async throws -> TemporaryPlaybackResolution {
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        activeResolutionTask?.cancel()
        let scanner = scanner
        let matcher = matcher
        let scopeAccess = scopeAccess
        let pool = workPool
        // Normalization, scanning and matching share one real-work budget.
        // Superseding a caller removes its queued work immediately, but a
        // blocked filesystem operation keeps the running slot and its scopes.
        let task = Task {
            try await pool.run {
                try await Self.prepareResolution(
                    requestedURLs: requestedURLs,
                    libraryItems: libraryItems,
                    librarySourceURLs: librarySourceURLs,
                    scanner: scanner,
                    matcher: matcher,
                    scopeAccess: scopeAccess
                )
            }
        }
        activeResolutionTask = task
        defer {
            if generation == resolutionGeneration {
                activeResolutionTask = nil
            }
        }
        let prepared = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard generation == resolutionGeneration else {
            throw CancellationError()
        }
        if !prepared.resolution.items.isEmpty {
            activeScopes = prepared.retainedScopes
        }
        return prepared.resolution
    }

    func end() {
        resolutionGeneration &+= 1
        activeResolutionTask?.cancel()
        activeResolutionTask = nil
        activeScopes.removeAll()
    }

    private nonisolated static func prepareResolution(
        requestedURLs: [URL],
        libraryItems: [LibraryMediaItem],
        librarySourceURLs: [URL],
        scanner: any MediaLibraryScanning,
        matcher: TemporaryPlaybackMatcher,
        scopeAccess: TemporaryPlaybackSecurityScopeAccess
    ) async throws -> PreparedResolution {
        // Matching also resolves library roots. Its independent claims use the
        // exact session URLs and outlive caller cancellation/source shutdown.
        let libraryScopes = librarySourceURLs.map {
            TemporaryPlaybackScopeLease(url: $0, access: scopeAccess)
        }
        defer { withExtendedLifetime(libraryScopes) {} }
        let batch = try supportedUniqueFiles(
            requestedURLs, canonicalPath: matcher.canonicalPath
        )
        guard !batch.urls.isEmpty else {
            return PreparedResolution(
                resolution: TemporaryPlaybackResolution(
                    items: [], temporaryItemIDs: [],
                    skippedItemCount: batch.skippedItemCount
                ),
                retainedScopes: []
            )
        }
        let scopes = batch.urls.map {
            TemporaryPlaybackScopeLease(url: $0, access: scopeAccess)
        }
        defer { withExtendedLifetime(scopes) {} }
        try Task.checkCancellation()
        let snapshot = try await scanner.scan(
            sources: batch.urls.map { MediaSource(url: $0, kind: .file) }
        )
        try Task.checkCancellation()
        let plan = try matcher.match(
            requestedFiles: batch.urls,
            requestedCanonicalPaths: batch.canonicalPaths,
            libraryItems: libraryItems,
            scannedItems: snapshot.items
        )
        return PreparedResolution(
            resolution: TemporaryPlaybackResolution(
                items: plan.items,
                temporaryItemIDs: plan.temporaryItemIDs,
                skippedItemCount: batch.skippedItemCount
                    + batch.urls.count - plan.items.count
            ),
            retainedScopes: scopes.enumerated().compactMap { index, scope in
                plan.retainsScopeByRequestedFileIndex[index] ? scope : nil
            }
        )
    }

    private nonisolated static func supportedUniqueFiles(
        _ urls: [URL],
        canonicalPath: TemporaryPlaybackMatcher.CanonicalPathResolver
    ) throws -> RequestedFileBatch {
        var knownPaths: Set<String> = []
        var supportedFiles: [URL] = []
        var canonicalPaths: [String] = []
        var skippedItemCount = 0
        supportedFiles.reserveCapacity(
            min(urls.count, MediaImportPolicy.maximumTopLevelSourceCount)
        )
        for requestedURL in urls {
            try Task.checkCancellation()
            guard requestedURL.isFileURL else {
                skippedItemCount += 1
                continue
            }
            let url = requestedURL.standardizedFileURL
            guard MediaLibraryFilePolicy.supportedVideoExtensions.contains(
                url.pathExtension.lowercased()
            ) else {
                skippedItemCount += 1
                continue
            }
            let path = canonicalPath(url)
            guard knownPaths.insert(path).inserted else { continue }
            guard supportedFiles.count
                    < MediaImportPolicy.maximumTopLevelSourceCount else {
                skippedItemCount += 1
                continue
            }
            supportedFiles.append(url)
            canonicalPaths.append(path)
        }
        return RequestedFileBatch(
            urls: supportedFiles,
            canonicalPaths: canonicalPaths,
            skippedItemCount: skippedItemCount
        )
    }
}
