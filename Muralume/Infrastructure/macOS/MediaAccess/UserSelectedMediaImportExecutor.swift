import Foundation

struct MediaSourceImportInspection: @unchecked Sendable {
    let kind: MediaSourceKind?
    let linkResolution: MediaSourceURLInspector.LinkResolution
    let resourceIdentifier: NSObject?
    let coveredByFolderPaths: Set<String>
    let containsFolderPaths: Set<String>
    let containsFilePaths: Set<String>
}

/// Owns either the consumed Powerbox grant or a separate balanced access
/// claim through background work. Cancelling the caller does not close the
/// claim while a blocked inspector/bookmark operation still retains it.
final class MediaImportIncomingScopeLease: @unchecked Sendable {
    let url: URL
    private let releaseScope: @Sendable (URL) -> Void

    init(url: URL, releaseScope: @escaping @Sendable (URL) -> Void) {
        self.url = url
        self.releaseScope = releaseScope
    }

    deinit { releaseScope(url) }
}

struct UserSelectedMediaImportExecutor: Sendable {
    typealias Inspection = @Sendable (
        URL, [String: MediaSource]
    ) -> MediaSourceImportInspection
    private let pool = BoundedMediaWorkPool(maximumConcurrentWorkCount: 2)
    private let inspectOperation: Inspection
    private let bookmarkOperation: @Sendable (URL) -> Data?
    private let beginIndependentScope: @Sendable (URL) -> Bool
    private let endIndependentScope: @Sendable (URL) -> Void
    private let releaseIncomingScope: @Sendable (URL) -> Void

    static let live = UserSelectedMediaImportExecutor()

    init(
        inspect: @escaping Inspection = Self.inspectSynchronously,
        makeBookmark: @escaping @Sendable (URL) -> Data? = { url in
            try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        beginIndependentScope: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        endIndependentScope: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        },
        releaseIncomingScope: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        inspectOperation = inspect
        bookmarkOperation = makeBookmark
        self.beginIndependentScope = beginIndependentScope
        self.endIndependentScope = endIndependentScope
        self.releaseIncomingScope = releaseIncomingScope
    }

    func incomingLease(
        for url: URL,
        policy: MediaAccessIncomingScopePolicy
    ) -> MediaImportIncomingScopeLease {
        switch policy {
        case .sessionManaged:
            return MediaImportIncomingScopeLease(url: url, releaseScope: releaseIncomingScope)
        case .callerManaged:
            let didBeginAccess = beginIndependentScope(url)
            return MediaImportIncomingScopeLease(url: url) { [endScope = endIndependentScope] url in
                if didBeginAccess { endScope(url) }
            }
        }
    }

    func inspect(
        _ lease: MediaImportIncomingScopeLease,
        activeSources: [String: MediaSource]
    ) async throws -> MediaSourceImportInspection {
        try await pool.run {
            defer { withExtendedLifetime(lease) {} }
            return inspectOperation(lease.url, activeSources)
        }
    }

    private static func inspectSynchronously(
        _ url: URL,
        activeSources: [String: MediaSource]
    ) -> MediaSourceImportInspection {
        let resolution = MediaSourceURLInspector.linkResolution(for: url)
        let targetURL = resolution.targetURL.standardizedFileURL
        let kind = MediaSourceURLInspector.liveSourceKind(at: targetURL)
        var coveredByFolderPaths: Set<String> = []
        var containsFolderPaths: Set<String> = []
        var containsFilePaths: Set<String> = []
        for (path, source) in activeSources {
            if Task.isCancelled { break }
            let activeURL = URL(fileURLWithPath: path)
            if source.kind == .folder,
               Self.covers(activeURL, targetURL) {
                coveredByFolderPaths.insert(path)
            }
            if kind == .folder, Self.covers(targetURL, activeURL) {
                if source.kind == .folder {
                    containsFolderPaths.insert(path)
                } else {
                    containsFilePaths.insert(path)
                }
            }
        }
        return MediaSourceImportInspection(
            kind: kind,
            linkResolution: resolution,
            resourceIdentifier: MediaSourceURLInspector.resourceIdentifier(
                for: targetURL
            ),
            coveredByFolderPaths: coveredByFolderPaths,
            containsFolderPaths: containsFolderPaths,
            containsFilePaths: containsFilePaths
        )
    }

    func makeBookmark(
        _ lease: MediaImportIncomingScopeLease
    ) async throws -> Data? {
        try await pool.run {
            defer { withExtendedLifetime(lease) {} }
            return bookmarkOperation(lease.url)
        }
    }

    private static func covers(_ folder: URL, _ item: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(
            &relationship,
            ofDirectoryAt: folder,
            toItemAt: item
        )
        return relationship != .other
    }
}
