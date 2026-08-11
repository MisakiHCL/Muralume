import Foundation

struct TemporaryPlaybackResolution: Sendable {
    let items: [LibraryMediaItem]
    let temporaryItemIDs: Set<LibraryMediaItem.ID>
    let skippedItemCount: Int
}

struct MediaLibraryPlaybackContext: Sendable {
    let queueSnapshot: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let currentTime: TimeInterval
    let playbackIntent: PlaybackIntent
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
    private var activeScopes: [SecurityScope] = []
    private var resolutionGeneration: UInt64 = 0

    init(scanner: any MediaLibraryScanning) {
        self.scanner = scanner
    }

    deinit {
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

        let libraryItemsByPath = Self.itemsByCanonicalPath(libraryItems)
        let scannedItemsByPath = Self.itemsByCanonicalPath(snapshot.items)
        var resolvedItems: [LibraryMediaItem] = []
        var temporaryItemIDs: Set<LibraryMediaItem.ID> = []
        resolvedItems.reserveCapacity(requestedFiles.count)

        for url in requestedFiles {
            let path = Self.canonicalPath(url)
            if let libraryItem = libraryItemsByPath[path] {
                resolvedItems.append(libraryItem)
                continue
            }
            guard let scannedItem = scannedItemsByPath[path] else {
                continue
            }
            resolvedItems.append(scannedItem)
            temporaryItemIDs.insert(scannedItem.id)
        }

        if !resolvedItems.isEmpty {
            let temporaryPaths = Set(
                resolvedItems.lazy
                    .filter { temporaryItemIDs.contains($0.id) }
                    .map { Self.canonicalPath($0.url) }
            )
            let retainedScopes = pendingScopes.filter {
                temporaryPaths.contains(Self.canonicalPath($0.url))
            }
            let unusedScopes = pendingScopes.filter {
                !temporaryPaths.contains(Self.canonicalPath($0.url))
            }
            Self.release(unusedScopes)
            Self.release(activeScopes)
            activeScopes = retainedScopes
            shouldReleasePendingScopes = false
        }

        return TemporaryPlaybackResolution(
            items: resolvedItems,
            temporaryItemIDs: temporaryItemIDs,
            skippedItemCount: requestedBatch.skippedItemCount
                + requestedFiles.count
                - resolvedItems.count
        )
    }

    func end() {
        resolutionGeneration &+= 1
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

    private static func itemsByCanonicalPath(
        _ items: [LibraryMediaItem]
    ) -> [String: LibraryMediaItem] {
        var result: [String: LibraryMediaItem] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            result[canonicalPath(item.url)] = item
        }
        return result
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
