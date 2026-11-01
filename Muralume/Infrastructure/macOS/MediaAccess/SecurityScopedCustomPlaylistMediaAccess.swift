import Foundation
import Darwin

struct CustomPlaylistFileMetadata: Sendable {
    var isDirectory = false
    var isRegularFile = true
    var creationDate: Date?
    var modificationDate: Date?
    var fileSize: Int64 = 0
    var fileIdentity: MediaFileIdentity?
}

struct CustomPlaylistBookmarkOperations: Sendable {
    struct Resolved: Sendable {
        let url: URL
        var isStale = false
    }

    var resolve: @Sendable (Data) throws -> Resolved
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void
    var makeBookmark: @Sendable (URL) throws -> Data
    var metadata: @Sendable (URL) throws -> CustomPlaylistFileMetadata
    var canonicalURL: @Sendable (URL) -> URL

    static let live = Self(
        resolve: { data in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
            return Resolved(url: url, isStale: stale)
        },
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() },
        makeBookmark: { try $0.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) },
        metadata: { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .creationDateKey,
                .contentModificationDateKey, .fileSizeKey,
                .volumeIdentifierKey, .fileResourceIdentifierKey
            ])
            func archived(_ value: Any?) -> Data? {
                guard let value = value as? NSObject, value is NSSecureCoding else { return nil }
                return try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
            }
            let identity: MediaFileIdentity?
            if let volume = archived(values.volumeIdentifier),
               let file = archived(values.fileResourceIdentifier) {
                identity = MediaFileIdentity(volumeIdentifier: volume, fileIdentifier: file)
            } else { identity = nil }
            return CustomPlaylistFileMetadata(
                isDirectory: values.isDirectory == true,
                isRegularFile: values.isRegularFile == true,
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate,
                fileSize: Int64(values.fileSize ?? 0), fileIdentity: identity
            )
        },
        canonicalURL: { $0.resolvingSymlinksInPath().standardizedFileURL }
    )
}

private final class PlaylistScopeBudget: @unchecked Sendable {
    final class Ticket: @unchecked Sendable {
        let budget: PlaylistScopeBudget
        init(_ budget: PlaylistScopeBudget) { self.budget = budget }
        deinit { budget.release() }
    }
    private let lock = NSLock()
    private var count = 0
    func acquire() -> Ticket? {
        lock.withLock {
            guard count < MediaImportPolicy.maximumActiveSourceCount else { return nil }
            count += 1
            return Ticket(self)
        }
    }
    private func release() { lock.withLock { count -= 1 } }
}

/// A stopped caller cannot release permission underneath its actual native worker.
private final class PlaylistScopedURL: @unchecked Sendable {
    private static let releaseQueue = DispatchQueue(label: "Muralume.PlaylistScopeRelease")
    let url: URL
    private let stop: @Sendable (URL) -> Void
    private let ticket: PlaylistScopeBudget.Ticket?

    init(url: URL, ticket: PlaylistScopeBudget.Ticket? = nil, stop: @escaping @Sendable (URL) -> Void) {
        self.url = url
        self.ticket = ticket
        self.stop = stop
    }
    deinit {
        Self.releaseQueue.async { [url, stop, ticket] in
            stop(url)
            withExtendedLifetime(ticket) {}
        }
    }
}

@MainActor
final class SecurityScopedCustomPlaylistMediaAccess: CustomPlaylistMediaAccessResolving {
    private struct AuthorizedGrant: Sendable {
        let grant: CustomPlaylistMediaGrant
        let rootURL: URL
        let canonicalRoot: URL
        let lease: MediaSourceAccessLease
    }
    private struct Result: Sendable {
        var resolution = CustomPlaylistMediaResolution()
        var grants: [UUID: AuthorizedGrant] = [:]
    }
    /// Native work commits only completed operations. A deadline seals the
    /// same storage once, so late work cannot mutate the returned snapshot.
    private final class Progress: @unchecked Sendable {
        private enum State { case pending, completed, expired }
        private let lock = NSLock()
        private var state = State.pending
        private var result = Result()

        func record(_ issue: CustomPlaylistMediaIssue, for entries: [CustomPlaylistEntry]) {
            lock.withLock {
                guard state == .pending else { return }
                for entry in entries { result.resolution.issuesByEntryID[entry.id] = issue }
            }
        }

        func record(_ issue: CustomPlaylistMediaIssue, for entry: CustomPlaylistEntry) {
            lock.withLock {
                guard state == .pending else { return }
                result.resolution.issuesByEntryID[entry.id] = issue
            }
        }

        func record(_ authorized: AuthorizedGrant, replacing grant: CustomPlaylistMediaGrant) {
            lock.withLock {
                guard state == .pending else { return }
                result.grants[grant.id] = authorized
                result.resolution.authorizedRootIDs.insert(.init(standardizedPath: grant.sourcePath))
                result.resolution.authorizedRootIDs.insert(.init(standardizedPath: authorized.grant.sourcePath))
                if authorized.grant != grant { result.resolution.refreshedGrants.append(authorized.grant) }
            }
        }

        func record(_ item: LibraryMediaItem, for entry: CustomPlaylistEntry) {
            lock.withLock {
                guard state == .pending else { return }
                result.resolution.itemsByEntryID[entry.id] = item
                result.resolution.authorizedRootIDs.insert(.init(standardizedPath: item.id.rootPath))
            }
        }

        func expireIfPending() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .expired
                return true
            }
        }

        func expiredResult() -> Result? {
            lock.withLock { state == .expired ? result : nil }
        }

        func finish(entries: [CustomPlaylistEntry]) -> Result {
            lock.withLock {
                guard state == .pending else { return result }
                for entry in entries where result.resolution.itemsByEntryID[entry.id] == nil
                    && result.resolution.issuesByEntryID[entry.id] == nil {
                    result.resolution.issuesByEntryID[entry.id] = .authorizationRequired
                }
                state = .completed
                return result
            }
        }
    }
    // Shared across instances: recreating a resolver cannot bypass blocked work.
    private static let pool = BoundedMediaWorkPool(maximumConcurrentWorkCount: 2, maximumQueuedWorkCount: 2)
    private static let budget = PlaylistScopeBudget()
    private let operations: CustomPlaylistBookmarkOperations
    private let deadline: Duration
    private var cache: [UUID: AuthorizedGrant] = [:]
    private var generation: UInt64 = 0
    private var running: Task<Result, Error>?
    private var authorizationTask: Task<CustomPlaylistMediaGrant?, Error>?
    private var authorizationGeneration: UInt64 = 0
    private var isShutDown = false

    init(operations: CustomPlaylistBookmarkOperations = .live, deadline: Duration = .seconds(10)) {
        self.operations = operations
        self.deadline = deadline
    }

    isolated deinit {
        running?.cancel()
        authorizationTask?.cancel()
    }

    func resolve(
        grants: [CustomPlaylistMediaGrant], entries: [CustomPlaylistEntry]
    ) async -> CustomPlaylistMediaResolution {
        generation &+= 1
        let revision = generation
        running?.cancel()
        let unavailable = CustomPlaylistMediaResolution(issuesByEntryID: Dictionary(
            entries.prefix(CustomPlaylistPolicy.maximumTotalEntryCount).map { ($0.id, CustomPlaylistMediaIssue.temporarilyUnavailable) },
            uniquingKeysWith: { first, _ in first }
        ))
        guard !isShutDown, !Task.isCancelled,
              grants.count <= MediaImportPolicy.maximumActiveSourceCount,
              entries.count <= CustomPlaylistPolicy.maximumTotalEntryCount else { return unavailable }
        let requested = Dictionary(grants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cache = cache.filter { requested[$0.key] == $0.value.grant }
        let previous = cache
        let operations = operations
        let pool = Self.pool
        let budget = Self.budget
        let progress = Progress()
        let task = Task {
            try await pool.run {
                try Self.prepare(grants: grants, entries: entries, previous: previous,
                                 operations: operations, budget: budget, progress: progress)
            }
        }
        running = task
        let timeout = Task { [deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            if progress.expireIfPending() { task.cancel() }
        }
        defer { timeout.cancel() }
        let completedResult = try? await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard revision == generation, !isShutDown, !Task.isCancelled,
              var result = completedResult ?? progress.expiredResult() else { return unavailable }
        for entry in entries where result.resolution.itemsByEntryID[entry.id] == nil
            && result.resolution.issuesByEntryID[entry.id] == nil {
            result.resolution.issuesByEntryID[entry.id] = .temporarilyUnavailable
        }
        running = nil
        cache = result.grants
        return result.resolution
    }

    func authorize(
        selectedURL: URL, sourcePath: String, kind: MediaSourceKind, grantID: UUID?
    ) async -> CustomPlaylistMediaGrant? {
        let operations = operations
        let incoming = PlaylistScopedURL(url: selectedURL, stop: operations.stopAccess)
        authorizationGeneration &+= 1
        let revision = authorizationGeneration
        authorizationTask?.cancel()
        guard !isShutDown, selectedURL.isFileURL, Self.validSourcePath(sourcePath) else { return nil }
        let pool = Self.pool
        let task = Task {
            try await pool.run {
                defer { withExtendedLifetime(incoming) {} }
                try Task.checkCancellation()
                let metadata = try operations.metadata(selectedURL)
                guard kind == .folder ? metadata.isDirectory : metadata.isRegularFile,
                      kind == .folder || MediaLibraryFilePolicy.supportedVideoExtensions.contains(selectedURL.pathExtension.lowercased()) else { return nil as CustomPlaylistMediaGrant? }
                let bookmark = try operations.makeBookmark(selectedURL)
                try Task.checkCancellation()
                guard !bookmark.isEmpty, bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount else { return nil }
                return CustomPlaylistMediaGrant(id: grantID ?? UUID(), sourcePath: sourcePath, kind: kind, bookmark: bookmark)
            }
        }
        authorizationTask = task
        let timeout = Task { [deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            task.cancel()
        }
        defer { timeout.cancel() }
        let grant = try? await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !isShutDown, revision == authorizationGeneration, !Task.isCancelled else { return nil }
        authorizationTask = nil
        return grant
    }

    func shutdown() async {
        isShutDown = true
        generation &+= 1
        running?.cancel()
        authorizationTask?.cancel()
        running = nil
        authorizationTask = nil
        cache.removeAll()
    }

    nonisolated private static func validSourcePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 16_384
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    nonisolated private static func prepare(
        grants: [CustomPlaylistMediaGrant], entries: [CustomPlaylistEntry],
        previous: [UUID: AuthorizedGrant], operations: CustomPlaylistBookmarkOperations,
        budget: PlaylistScopeBudget, progress: Progress
    ) throws -> Result {
        let grouped = Dictionary(grouping: entries, by: \.accessGrantID)
        progress.record(.authorizationRequired, for: grouped[nil] ?? [])
        var seen: Set<UUID> = []
        for grant in grants {
            try Task.checkCancellation()
            guard let group = grouped[grant.id], !group.isEmpty else { continue }
            guard seen.insert(grant.id).inserted,
                  validSourcePath(grant.sourcePath), !grant.bookmark.isEmpty,
                  grant.bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount else {
                progress.record(.authorizationRequired, for: group)
                continue
            }
            let authorized: AuthorizedGrant
            do {
                if let existing = previous[grant.id], existing.grant == grant {
                    authorized = existing
                } else {
                    guard let ticket = budget.acquire() else {
                        progress.record(.temporarilyUnavailable, for: group)
                        continue
                    }
                    let resolved = try operations.resolve(grant.bookmark)
                    try Task.checkCancellation()
                    guard resolved.url.isFileURL else {
                        progress.record(.authorizationRequired, for: group)
                        continue
                    }
                    guard operations.startAccess(resolved.url) else {
                        progress.record(.permissionDenied, for: group)
                        continue
                    }
                    let owner = PlaylistScopedURL(url: resolved.url, ticket: ticket, stop: operations.stopAccess)
                    let lease = MediaSourceAccessLease(retaining: owner)
                    try Task.checkCancellation()
                    let rootMetadata = try operations.metadata(resolved.url)
                    try Task.checkCancellation()
                    guard grant.kind == .folder ? rootMetadata.isDirectory : rootMetadata.isRegularFile else {
                        progress.record(.cannotOpen, for: group)
                        continue
                    }
                    let resolvedSourcePath = resolved.url.standardizedFileURL.path
                    var current = CustomPlaylistMediaGrant(
                        id: grant.id, sourcePath: resolvedSourcePath, kind: grant.kind, bookmark: grant.bookmark
                    )
                    if resolved.isStale, let bookmark = try? operations.makeBookmark(resolved.url),
                       !bookmark.isEmpty, bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount {
                        current = CustomPlaylistMediaGrant(id: grant.id, sourcePath: resolvedSourcePath, kind: grant.kind, bookmark: bookmark)
                    }
                    try Task.checkCancellation()
                    let canonicalRoot = operations.canonicalURL(resolved.url)
                    try Task.checkCancellation()
                    authorized = AuthorizedGrant(grant: current, rootURL: resolved.url,
                        canonicalRoot: canonicalRoot, lease: lease)
                }
                progress.record(authorized, replacing: grant)
            } catch is CancellationError { throw CancellationError() }
            catch {
                progress.record(issue(for: error, resolvingGrant: true), for: group)
                continue
            }
            for entry in group {
                try Task.checkCancellation()
                do {
                    let original = entry.media.mediaItemID
                    guard validSourcePath(original.rootPath),
                          !original.relativePath.hasPrefix("/"),
                          !original.relativePath.utf8.contains(0),
                          original.relativePath.utf8.count <= 16_384,
                          !original.relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                        progress.record(.permissionDenied, for: entry)
                        continue
                    }
                    let sourceParts = URL(fileURLWithPath: grant.sourcePath).pathComponents
                    let itemParts = URL(fileURLWithPath: original.standardizedMediaPath).pathComponents
                    guard itemParts.starts(with: sourceParts),
                          grant.kind == .folder ? itemParts.count > sourceParts.count : itemParts == sourceParts else {
                        progress.record(.authorizationRequired, for: entry)
                        continue
                    }
                    let relative = itemParts.dropFirst(sourceParts.count).joined(separator: "/")
                    let url = relative.isEmpty ? authorized.rootURL : authorized.rootURL.appendingPathComponent(relative)
                    let canonical = operations.canonicalURL(url)
                    try Task.checkCancellation()
                    guard grant.kind == .folder
                        ? canonical.pathComponents.starts(with: authorized.canonicalRoot.pathComponents)
                        : canonical.path == authorized.canonicalRoot.path else {
                        progress.record(.permissionDenied, for: entry)
                        continue
                    }
                    let metadata = try operations.metadata(url)
                    try Task.checkCancellation()
                    guard metadata.isRegularFile else {
                        progress.record(.cannotOpen, for: entry)
                        continue
                    }
                    guard MediaLibraryFilePolicy.supportedVideoExtensions.contains(url.pathExtension.lowercased()) else {
                        progress.record(.unsupportedFormat, for: entry)
                        continue
                    }
                    let item = LibraryMediaItem(
                        rootURL: authorized.rootURL, rootName: authorized.rootURL.lastPathComponent,
                        kind: grant.kind, url: url, displayName: url.deletingPathExtension().lastPathComponent,
                        relativePath: relative, relativeDirectory: (relative as NSString).deletingLastPathComponent,
                        creationDate: metadata.creationDate, modificationDate: metadata.modificationDate,
                        fileSize: metadata.fileSize, fileIdentity: metadata.fileIdentity, accessLease: authorized.lease
                    )
                    progress.record(item, for: entry)
                } catch is CancellationError { throw CancellationError() }
                catch { progress.record(issue(for: error, resolvingGrant: false), for: entry) }
            }
        }
        return progress.finish(entries: entries)
    }

    nonisolated private static func issue(for error: Error, resolvingGrant: Bool) -> CustomPlaylistMediaIssue {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
            || error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return .permissionDenied }
        if !resolvingGrant && (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return .fileMissing }
        return .temporarilyUnavailable
    }
}
