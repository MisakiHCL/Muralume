import Foundation

struct MediaLibraryCanonicalLookupIndex: Sendable {
    struct RootResolution: Sendable {
        let rootURL: URL
        let canonicalPath: String
        let canonicalComponents: [String]
    }
    let contentRevision: UInt64
    let rootResolutions: [RootResolution]
}

struct MediaLibraryCanonicalLookupRequest: Sendable {
    let urls: [URL]
    let items: [LibraryMediaItem]
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let rootURLsByPath: [String: URL]
    let contentRevision: UInt64
    let cachedIndex: MediaLibraryCanonicalLookupIndex?
    let sourceURLs: [URL]
}

struct PreparedMediaLibraryCanonicalLookup: Sendable {
    let matches: [LibraryMediaItem?]
    let index: MediaLibraryCanonicalLookupIndex?
    let rebuiltIndex: Bool
}

/// Only the actual filesystem worker owns these claims. Caller cancellation
/// releases the caller, while a blocked resolver retains its scopes and slot.
private final class CanonicalLookupScope: @unchecked Sendable {
    private let url: URL
    private let access: TemporaryPlaybackSecurityScopeAccess
    private let started: Bool
    init(url: URL, access: TemporaryPlaybackSecurityScopeAccess) {
        self.url = url
        self.access = access
        started = access.startAccess(url)
    }
    deinit { if started { access.stopAccess(url) } }
}

struct MediaLibraryCanonicalLookup: Sendable {
    typealias Resolver = @Sendable (URL) -> URL
    let resolve: Resolver
    let scopeAccess: TemporaryPlaybackSecurityScopeAccess

    init(
        resolve: @escaping Resolver = { $0.resolvingSymlinksInPath().standardizedFileURL },
        scopeAccess: TemporaryPlaybackSecurityScopeAccess = .live
    ) {
        self.resolve = resolve
        self.scopeAccess = scopeAccess
    }

    func prepare(_ request: MediaLibraryCanonicalLookupRequest) throws
        -> PreparedMediaLibraryCanonicalLookup {
        try Task.checkCancellation()
        let scopes = (request.sourceURLs + request.urls).map {
            CanonicalLookupScope(url: $0, access: scopeAccess)
        }
        defer { withExtendedLifetime(scopes) {} }
        var matches = request.urls.map {
            request.itemsByID[LibraryMediaItem.ID(mediaURL: $0)]
        }
        guard matches.contains(where: { $0 == nil }) else {
            return .init(matches: matches, index: request.cachedIndex, rebuiltIndex: false)
        }
        var cachedIndexIsValid = false
        if let cached = request.cachedIndex,
           cached.contentRevision == request.contentRevision {
            cachedIndexIsValid = true
            for root in cached.rootResolutions {
                try Task.checkCancellation()
                if resolve(root.rootURL).path != root.canonicalPath {
                    cachedIndexIsValid = false
                    break
                }
            }
        }
        let index: MediaLibraryCanonicalLookupIndex
        if cachedIndexIsValid, let cached = request.cachedIndex {
            index = cached
        } else {
            var resolutions: [MediaLibraryCanonicalLookupIndex.RootResolution] = []
            for root in request.rootURLsByPath.values {
                try Task.checkCancellation()
                let canonical = resolve(root)
                resolutions.append(.init(
                    rootURL: root, canonicalPath: canonical.path,
                    canonicalComponents: canonical.pathComponents
                ))
            }
            index = .init(contentRevision: request.contentRevision, rootResolutions: resolutions)
        }
        for offset in request.urls.indices where matches[offset] == nil {
            try Task.checkCancellation()
            let components = resolve(request.urls[offset]).pathComponents
            var matchedIDs: Set<LibraryMediaItem.ID> = []
            for root in index.rootResolutions {
                guard components.starts(with: root.canonicalComponents) else { continue }
                let relativePath = components.dropFirst(root.canonicalComponents.count).joined(separator: "/")
                let id = LibraryMediaItem.ID(
                    rootPath: root.rootURL.standardizedFileURL.path, relativePath: relativePath
                )
                if request.itemsByID[id] != nil { matchedIDs.insert(id) }
            }
            if matchedIDs.count == 1, let id = matchedIDs.first {
                matches[offset] = request.itemsByID[id]
            } else if !matchedIDs.isEmpty {
                // Keep the original last-item-wins behavior for alias roots.
                matches[offset] = request.items.last { matchedIDs.contains($0.id) }
            }
        }
        try Task.checkCancellation()
        return .init(matches: matches, index: index, rebuiltIndex: !cachedIndexIsValid)
    }
}
