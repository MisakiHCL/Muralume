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

        for (index, url) in requestedFiles.enumerated() {
            try Task.checkCancellation()
            let path = canonicalPath(url)
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

@MainActor
final class TemporaryPlaybackSession {
    private struct RequestedFileBatch {
        let urls: [URL]
        let skippedItemCount: Int
    }

    private struct SecurityScope {
        let url: URL
        let didStart: Bool
    }

    private let scanner: any MediaLibraryScanning
    private let matcher: TemporaryPlaybackMatcher
    private var activeScopes: [SecurityScope] = []
    private var activeMatchTask: Task<TemporaryPlaybackMatchPlan, Error>?
    private var resolutionGeneration: UInt64 = 0

    init(
        scanner: any MediaLibraryScanning,
        canonicalPath: @escaping @Sendable (URL) -> String = {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        }
    ) {
        self.scanner = scanner
        matcher = TemporaryPlaybackMatcher(canonicalPath: canonicalPath)
    }

    deinit {
        activeMatchTask?.cancel()
        for scope in activeScopes where scope.didStart {
            scope.url.stopAccessingSecurityScopedResource()
        }
    }

    func resolve(
        _ requestedURLs: [URL],
        libraryItems: [LibraryMediaItem]
    ) async throws -> TemporaryPlaybackResolution {
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        activeMatchTask?.cancel()
        activeMatchTask = nil
        let requestedBatch = Self.supportedUniqueFiles(requestedURLs)
        let requestedFiles = requestedBatch.urls
        guard !requestedFiles.isEmpty else {
            return TemporaryPlaybackResolution(
                items: [],
                temporaryItemIDs: [],
                skippedItemCount: requestedBatch.skippedItemCount
            )
        }

        let pendingScopes = requestedFiles.map { url in
            SecurityScope(
                url: url,
                didStart: url.startAccessingSecurityScopedResource()
            )
        }
        var shouldReleasePendingScopes = true
        defer {
            if shouldReleasePendingScopes {
                Self.release(pendingScopes)
            }
        }

        let snapshot = try await scanner.scan(
            sources: requestedFiles.map {
                MediaSource(url: $0, kind: .file)
            }
        )
        try Task.checkCancellation()
        guard generation == resolutionGeneration else {
            throw CancellationError()
        }

        let matcher = matcher
        let matchTask = Task.detached(priority: .userInitiated) {
            try matcher.match(
                requestedFiles: requestedFiles,
                libraryItems: libraryItems,
                scannedItems: snapshot.items
            )
        }
        activeMatchTask = matchTask
        defer {
            if generation == resolutionGeneration {
                activeMatchTask = nil
            }
        }
        let matchPlan = try await withTaskCancellationHandler {
            try await matchTask.value
        } onCancel: {
            matchTask.cancel()
        }
        try Task.checkCancellation()
        guard generation == resolutionGeneration else {
            throw CancellationError()
        }

        if !matchPlan.items.isEmpty {
            let retainedScopes = pendingScopes.enumerated().compactMap {
                index, scope in
                matchPlan.retainsScopeByRequestedFileIndex[index]
                    ? scope
                    : nil
            }
            let unusedScopes = pendingScopes.enumerated().compactMap {
                index, scope in
                matchPlan.retainsScopeByRequestedFileIndex[index]
                    ? nil
                    : scope
            }
            Self.release(unusedScopes)
            Self.release(activeScopes)
            activeScopes = retainedScopes
            shouldReleasePendingScopes = false
        }

        return TemporaryPlaybackResolution(
            items: matchPlan.items,
            temporaryItemIDs: matchPlan.temporaryItemIDs,
            skippedItemCount: requestedBatch.skippedItemCount
                + requestedFiles.count
                - matchPlan.items.count
        )
    }

    func end() {
        resolutionGeneration &+= 1
        activeMatchTask?.cancel()
        activeMatchTask = nil
        Self.release(activeScopes)
        activeScopes.removeAll()
    }

    private static func supportedUniqueFiles(
        _ urls: [URL]
    ) -> RequestedFileBatch {
        var knownPaths: Set<String> = []
        var supportedFiles: [URL] = []
        var skippedItemCount = 0
        supportedFiles.reserveCapacity(
            min(urls.count, MediaImportPolicy.maximumTopLevelSourceCount)
        )

        for requestedURL in urls {
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
            guard knownPaths.insert(canonicalPath(url)).inserted else {
                continue
            }
            guard supportedFiles.count
                    < MediaImportPolicy.maximumTopLevelSourceCount else {
                skippedItemCount += 1
                continue
            }
            supportedFiles.append(url)
        }

        return RequestedFileBatch(
            urls: supportedFiles,
            skippedItemCount: skippedItemCount
        )
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func release(_ scopes: [SecurityScope]) {
        for scope in scopes where scope.didStart {
            scope.url.stopAccessingSecurityScopedResource()
        }
    }
}
