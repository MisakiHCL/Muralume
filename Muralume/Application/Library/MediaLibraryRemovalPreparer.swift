import Foundation

struct MediaLibraryRemovalRequest: Sendable {
    let root: MediaLibraryRoot
    let remainingSources: [MediaSource]
    let sourceAccessURLs: [URL]
    let library: PreparedMediaLibraryItems
    let queue: PlaybackQueue<LibraryMediaItem.ID>?
    let currentItemID: LibraryMediaItem.ID?
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let unavailableItemIDs: Set<LibraryMediaItem.ID>
    let supersededThumbnailRootPaths: Set<String>
}

struct MediaLibraryRemovalPlan: Sendable {
    let library: PreparedMediaLibraryItems
    let libraryChanged: Bool
    let queue: PlaybackQueue<LibraryMediaItem.ID>?
    let queueChanged: Bool
    let queueItemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let removedCurrentItem: Bool
    let removedItemIDs: Set<LibraryMediaItem.ID>
    let thumbnailRootIDs: Set<MediaLibraryRoot.ID>
    let supersededThumbnailRootPaths: Set<String>
}

protocol MediaLibraryRemovalPreparing: Sendable {
    func prepare(_ request: MediaLibraryRemovalRequest) async throws
        -> MediaLibraryRemovalPlan
}

/// A cancelled caller can return during shutdown while a blocked filesystem
/// reader retains its own access, just like the scan and thumbnail workers.
final class MediaLibraryRemovalScopeLease {
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private var acquiredURLs: [URL] = []
    private var seenPaths: Set<String> = []

    init(
        startAccess: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccess: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func acquire(for request: MediaLibraryRemovalRequest) throws {
        // Prefer the original bookmark-resolved URL over standardized model
        // URLs, including the source whose session grant will be removed.
        for url in request.sourceAccessURLs { try acquire(url) }
        try acquire(request.root.url)
        for source in request.remainingSources { try acquire(source.url) }
        for url in request.library.rootURLsByPath.values { try acquire(url) }
        for item in request.queueItemsByID.values { try acquire(item.rootURL) }
    }

    private func acquire(_ url: URL) throws {
        try Task.checkCancellation()
        guard seenPaths.insert(url.standardizedFileURL.path).inserted else { return }
        if startAccess(url) { acquiredURLs.append(url) }
    }

    deinit {
        for url in acquiredURLs { stopAccess(url) }
    }
}

/// All path resolution, index construction and queue transformation runs in
/// the coordinator's bounded worker. The request retains the previous library
/// through the commit so its final release also happens away from AppKit.
struct DefaultMediaLibraryRemovalPreparer: MediaLibraryRemovalPreparing {
    var canonicalURL: @Sendable (URL) -> URL = {
        $0.resolvingSymlinksInPath().standardizedFileURL
    }

    private struct Path {
        let canonical: [String]
    }

    private struct SourcePath {
        let kind: MediaSourceKind
        let path: Path

        func covers(_ candidate: Path) -> Bool {
            // Canonical containment is mandatory: a descendant symlink must
            // never transfer ownership to a folder it escapes.
            switch kind {
            case .file: candidate.canonical == path.canonical
            case .folder: candidate.canonical.starts(with: path.canonical)
            }
        }
    }

    func prepare(_ request: MediaLibraryRemovalRequest) async throws
        -> MediaLibraryRemovalPlan {
        try Task.checkCancellation()
        func path(_ url: URL) -> Path {
            Path(canonical: canonicalURL(url).pathComponents)
        }
        let removedSource = SourcePath(kind: request.root.kind, path: path(request.root.url))
        var remainingSources: [SourcePath] = []
        for source in request.remainingSources {
            try Task.checkCancellation()
            remainingSources.append(SourcePath(kind: source.kind, path: path(source.url)))
        }
        var paths: [String: Path] = [:]
        func cachedPath(_ url: URL) -> Path {
            let key = url.standardizedFileURL.path
            if let existing = paths[key] { return existing }
            let resolved = path(url)
            paths[key] = resolved
            return resolved
        }
        var removedIDs: Set<LibraryMediaItem.ID> = []
        var thumbnailRoots: Set<MediaLibraryRoot.ID> = [request.root.id]
        func inspect(_ item: LibraryMediaItem) throws {
            try Task.checkCancellation()
            let itemPath = cachedPath(item.rootURL)
            if removedSource.covers(itemPath),
               !remainingSources.contains(where: { $0.covers(itemPath) }) {
                removedIDs.insert(item.id)
                thumbnailRoots.insert(.init(standardizedPath: item.id.rootPath))
            }
        }
        for item in request.queueItemsByID.values { try inspect(item) }
        for item in request.library.items { try inspect(item) }
        var supersededPaths: Set<String> = []
        for rootPath in request.supersededThumbnailRootPaths {
            try Task.checkCancellation()
            if removedSource.covers(cachedPath(URL(fileURLWithPath: rootPath))) {
                supersededPaths.insert(rootPath)
                thumbnailRoots.insert(.init(standardizedPath: rootPath))
            }
        }
        var retainedItems: [LibraryMediaItem] = []
        var retainedByID: [LibraryMediaItem.ID: LibraryMediaItem] = [:]
        for item in request.library.items {
            try Task.checkCancellation()
            if !removedIDs.contains(item.id) {
                retainedItems.append(item)
                retainedByID[item.id] = item
            }
        }
        let libraryChanged = retainedItems.count != request.library.items.count
        let library = libraryChanged ? PreparedMediaLibraryItems(
            items: retainedItems, itemsByID: retainedByID,
            orderingContext: request.library.orderingContext
        ) : request.library
        var queueItems = request.queueItemsByID
        for id in removedIDs { queueItems[id] = nil }
        var queue = request.queue
        let queueChanged = !removedIDs.isEmpty && queue != nil
        let removedCurrent = request.currentItemID.map(removedIDs.contains) == true
        if queueChanged, var updated = queue {
            var next = updated.remove(removedIDs)
            if removedCurrent, let candidate = next,
               request.unavailableItemIDs.contains(candidate) {
                next = nil
                for _ in 0..<updated.count {
                    try Task.checkCancellation()
                    guard let id = updated.moveToNext() else { break }
                    if id != candidate, !request.unavailableItemIDs.contains(id) {
                        next = id
                        break
                    }
                }
            }
            queue = updated.isEmpty || next == nil ? nil : updated
            if queue == nil { queueItems = [:] }
        }
        try Task.checkCancellation()
        return MediaLibraryRemovalPlan(
            library: library, libraryChanged: libraryChanged,
            queue: queue, queueChanged: queueChanged, queueItemsByID: queueItems,
            removedCurrentItem: removedCurrent, removedItemIDs: removedIDs,
            thumbnailRootIDs: thumbnailRoots, supersededThumbnailRootPaths: supersededPaths
        )
    }
}
