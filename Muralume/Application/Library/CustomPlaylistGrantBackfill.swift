import Foundation

/// Exports existing source records without opening media. Work is bounded by
/// the persisted entry/source limits, and all edits stay in a local collection
/// until validation succeeds.
@MainActor
enum CustomPlaylistGrantBackfill {
    static func captureItems(
        _ items: [LibraryMediaItem], requireAll: Bool,
        capture: CustomPlaylistController.GrantCapture?
    ) throws -> [LibraryMediaItem.ID: CustomPlaylistMediaGrant] {
        guard let capture else { return [:] }
        var result: [LibraryMediaItem.ID: CustomPlaylistMediaGrant] = [:]
        var bySource: [String: CustomPlaylistMediaGrant] = [:]
        var failedSources: Set<String> = []
        for item in items {
            let key = item.kind.rawValue + ":" + item.rootURL.standardizedFileURL.path
            if let grant = bySource[key] {
                result[item.id] = grant
                continue
            }
            if failedSources.contains(key) { continue }
            guard let grant = capture(item), CustomPlaylistCollection.isValidAccessGrant(grant),
                  grant.kind == item.kind,
                  grant.sourcePath == item.rootURL.standardizedFileURL.path else {
                if requireAll { throw CustomPlaylistMutationError.authorizationUnavailable }
                failedSources.insert(key)
                continue
            }
            bySource[key] = grant
            result[item.id] = grant
        }
        return result
    }

    static func collection(
        byBackfilling collection: CustomPlaylistCollection,
        items: [LibraryMediaItem], index suppliedIndex: MediaReferenceResolutionIndex?,
        itemCapture: CustomPlaylistController.GrantCapture?,
        sourceCapture: CustomPlaylistController.SourceGrantCapture?
    ) throws -> CustomPlaylistCollection {
        var updated = collection
        if let sourceCapture {
            let paths = Set(collection.allEntries.filter { $0.accessGrantID == nil }.map {
                $0.media.mediaItemID.rootPath
            })
            for path in paths.sorted() {
                let sourceID = MediaSource.ID(standardizedPath: URL(fileURLWithPath: path).standardizedFileURL.path)
                guard let grant = sourceCapture(sourceID),
                      CustomPlaylistCollection.isValidAccessGrant(grant),
                      grant.sourcePath == sourceID.standardizedPath else { continue }
                _ = try updated.installReauthorizedGrant(grant, legacySourcePath: path)
            }
        }
        if !items.isEmpty {
            updated = try reconcilingAuthorizedLibraryItems(
                in: updated, index: suppliedIndex ?? MediaReferenceResolutionIndex(items: items),
                itemCapture: itemCapture, sourceCapture: sourceCapture
            )
        }
        guard updated.isValid else { throw CustomPlaylistStoreError.invalidCollection }
        return updated
    }

    /// A stable-file match proves identity, not permission. A move may adopt
    /// only a destination grant exported by its currently authorized source.
    private static func reconcilingAuthorizedLibraryItems(
        in collection: CustomPlaylistCollection, index: MediaReferenceResolutionIndex,
        itemCapture: CustomPlaylistController.GrantCapture?,
        sourceCapture: CustomPlaylistController.SourceGrantCapture?
    ) throws -> CustomPlaylistCollection {
        let originalGrants = Dictionary(uniqueKeysWithValues: collection.accessGrants.map { ($0.id, $0) })
        var grantsBySource: [String: CustomPlaylistMediaGrant] = [:]
        var attemptedSources: Set<String> = []
        var candidates: [CustomPlaylistEntry.ID: LibraryMediaItem] = [:]
        for playlist in collection.playlists {
            // Reserve every exact match before identity fallbacks, including
            // entries whose authorization cannot be adopted by this operation.
            let resolved = index.resolveReferences(playlist.entries.map(\.media))
            for (entry, candidate) in zip(playlist.entries, resolved) {
                guard safeReference(entry.media), let candidate,
                      candidate.url.isFileURL,
                      candidate.url.standardizedFileURL.path == candidate.id.standardizedMediaPath else { continue }
                let previous = entry.accessGrantID.flatMap { originalGrants[$0] }
                if entry.accessGrantID != nil {
                    guard let previous, covers(entry.media, with: previous) else { continue }
                }
                let key = sourceKey(path: candidate.id.rootPath, kind: candidate.kind)
                if attemptedSources.insert(key).inserted {
                    let captured = itemCapture?(candidate)
                        ?? sourceCapture?(.init(standardizedPath: candidate.id.rootPath))
                    if let captured, covers(candidate, with: captured) {
                        grantsBySource[key] = captured
                    }
                }
                // Existing independent folder permission remains sufficient
                // for a rename inside that same root, even after library removal.
                if grantsBySource[key] == nil, let previous, covers(candidate, with: previous) {
                    grantsBySource[key] = previous
                }
                guard grantsBySource[key] != nil else { continue }
                candidates[entry.id] = candidate
            }
        }
        guard !candidates.isEmpty else { return collection }

        var reconciled = collection
        // Keep the established duplicate-file-identity repair rather than
        // independently adopting a conflicting identity in each selected row.
        _ = reconciled.reconcile(using: index)
        let proposed = Dictionary(uniqueKeysWithValues: reconciled.allEntries.map { ($0.id, $0) })
        let playlists = collection.playlists.map { playlist in
            let entries = playlist.entries.map { entry -> CustomPlaylistEntry in
                guard let candidate = candidates[entry.id],
                      let grant = grantsBySource[sourceKey(path: candidate.id.rootPath, kind: candidate.kind)],
                      covers(candidate, with: grant), let replacement = proposed[entry.id],
                      replacement.media.mediaItemID == candidate.id else { return entry }
                return CustomPlaylistEntry(id: entry.id, media: replacement.media, accessGrantID: grant.id)
            }
            return CustomPlaylist(
                id: playlist.id, name: playlist.name, entries: entries,
                createdAt: playlist.createdAt, updatedAt: playlist.updatedAt
            )
        }
        var updated = CustomPlaylistCollection(playlists: playlists, accessGrants: collection.accessGrants)
        for key in grantsBySource.keys.sorted() {
            guard let grant = grantsBySource[key] else { continue }
            // Stage the proven references first so model garbage collection
            // retains a new destination grant while canonical IDs are merged.
            // A bookmark that followed a root rename also moves missing
            // siblings; a different destination keeps its own scoped bookmark.
            _ = try updated.installReauthorizedGrant(grant, legacySourcePath: grant.sourcePath)
        }
        updated.removeUnreferencedAccessGrants()
        guard updated.isValid else { throw CustomPlaylistStoreError.invalidCollection }
        return updated
    }

    private static func sourceKey(path: String, kind: MediaSourceKind) -> String {
        kind.rawValue + ":" + path
    }

    private static func safePath(_ path: String, absolute: Bool) -> Bool {
        (absolute ? path.hasPrefix("/") : !path.hasPrefix("/"))
            && !path.utf8.contains(0)
            && path.utf8.count <= CustomPlaylistPolicy.maximumMediaPathByteCount
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func safeReference(_ reference: MediaReference) -> Bool {
        safePath(reference.mediaItemID.rootPath, absolute: true)
            && safePath(reference.mediaItemID.relativePath, absolute: false)
    }

    private static func covers(_ reference: MediaReference, with grant: CustomPlaylistMediaGrant) -> Bool {
        guard CustomPlaylistCollection.isValidAccessGrant(grant), safeReference(reference),
              safePath(grant.sourcePath, absolute: true) else { return false }
        let source = URL(fileURLWithPath: grant.sourcePath).pathComponents
        let item = URL(fileURLWithPath: reference.mediaItemID.standardizedMediaPath).pathComponents
        return grant.kind == .file ? item == source
            : item.count > source.count && item.starts(with: source)
    }

    private static func covers(_ item: LibraryMediaItem, with grant: CustomPlaylistMediaGrant) -> Bool {
        grant.kind == item.kind && grant.sourcePath == item.id.rootPath
            && covers(MediaReference(item: item), with: grant)
    }
}
