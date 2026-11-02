import Foundation

@MainActor
struct CustomPlaylistVideoImporter: CustomPlaylistVideoImporting {
    private let executor: UserSelectedMediaImportExecutor
    private let deadline: Duration

    init(executor: UserSelectedMediaImportExecutor = .live, deadline: Duration = .seconds(10)) {
        self.executor = executor
        self.deadline = deadline
    }

    func prepare(_ selectedURLs: [URL]) async throws -> CustomPlaylistVideoImport {
        // Take ownership before checking cancellation. Retain only the bounded
        // transaction; excess selections are released without inspecting them.
        var leases: [MediaImportIncomingScopeLease] = []
        for url in selectedURLs {
            let lease = executor.incomingLease(for: url, policy: .sessionManaged)
            if leases.count < MediaImportPolicy.maximumTopLevelSourceCount { leases.append(lease) }
        }
        defer { withExtendedLifetime(leases) {} }
        guard selectedURLs.count <= MediaImportPolicy.maximumTopLevelSourceCount else {
            throw CustomPlaylistVideoImportError.selectionLimitReached
        }
        try Task.checkCancellation()
        let executor = executor
        let task = Task {
            var items: [LibraryMediaItem] = []
            var grants: [LibraryMediaItem.ID: CustomPlaylistMediaGrant] = [:]
            for lease in leases {
                try Task.checkCancellation()
                let url = lease.url.standardizedFileURL
                guard url.isFileURL else { throw CustomPlaylistVideoImportError.unavailable }
                let inspection = try await executor.inspect(lease, activeSources: [:])
                guard inspection.kind == .file, !inspection.linkResolution.didResolveLink,
                      MediaLibraryFilePolicy.supportedVideoExtensions.contains(url.pathExtension.lowercased()) else {
                    throw CustomPlaylistVideoImportError.unavailable
                }
                let id = LibraryMediaItem.ID(mediaURL: url)
                guard grants[id] == nil else { continue }
                guard let bookmark = try await executor.makeBookmark(lease), !bookmark.isEmpty,
                      bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount else {
                    throw CustomPlaylistVideoImportError.unavailable
                }
                try Task.checkCancellation()
                let item = LibraryMediaItem(
                    rootURL: url, rootName: url.lastPathComponent, kind: .file, url: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    relativePath: "", relativeDirectory: "", creationDate: nil, fileSize: 0
                )
                items.append(item)
                grants[id] = CustomPlaylistMediaGrant(sourcePath: url.path, kind: .file, bookmark: bookmark)
            }
            return CustomPlaylistVideoImport(items: items, grantsByItemID: grants)
        }
        let timeout = Task { [deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            task.cancel()
        }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            throw CustomPlaylistVideoImportError.unavailable
        }
    }
}
