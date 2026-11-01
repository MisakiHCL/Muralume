import Foundation

enum CustomPlaylistPolicy {
    static let maximumPlaylistCount = 256
    static let maximumEntriesPerPlaylist = 10_000
    static let maximumTotalEntryCount = 20_000
    static let maximumNameByteCount = 256
    static let maximumFileByteCount = 16 * 1_024 * 1_024
    static let maximumMediaPathByteCount = 16_384
}

enum CustomPlaylistMutationError: Error, Equatable, Sendable {
    case invalidName
    case duplicateName
    case playlistNotFound
    case playlistLimitReached
    case entryLimitReached
    case authorizationUnavailable
}

struct CustomPlaylistEntry: Codable, Equatable, Identifiable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    private(set) var media: MediaReference
    private(set) var accessGrantID: UUID?

    init(id: ID = ID(), media: MediaReference, accessGrantID: UUID? = nil) {
        self.id = id
        self.media = media
        self.accessGrantID = accessGrantID
    }

    mutating func update(using item: LibraryMediaItem) {
        media.update(using: item)
    }

    fileprivate mutating func relocateAccessRoot(
        from sourcePath: String, to destinationPath: String, kind: MediaSourceKind
    ) {
        let original = media.mediaItemID
        func safeAbsolute(_ path: String) -> Bool {
            path.hasPrefix("/") && safeComponents(path)
        }
        func safeComponents(_ path: String) -> Bool {
            !path.utf8.contains(0) && path.utf8.count <= CustomPlaylistPolicy.maximumMediaPathByteCount
                && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }
        guard sourcePath != destinationPath,
              safeAbsolute(sourcePath), safeAbsolute(destinationPath), safeAbsolute(original.rootPath),
              !original.relativePath.hasPrefix("/"), safeComponents(original.relativePath) else { return }
        let source = URL(fileURLWithPath: sourcePath).pathComponents
        let item = URL(fileURLWithPath: original.standardizedMediaPath).pathComponents
        guard item.starts(with: source),
              kind == .folder ? item.count > source.count : item == source else { return }
        let relativePath = item.dropFirst(source.count).joined(separator: "/")
        media = MediaReference(
            mediaItemID: .init(rootPath: destinationPath, relativePath: relativePath),
            fileIdentity: media.fileIdentity, lastKnownDisplayName: media.lastKnownDisplayName
        )
    }

    mutating func attachAccessGrant(_ id: UUID) { accessGrantID = id }
}

struct CustomPlaylist: Codable, Equatable, Identifiable, Sendable {
    struct ID: Codable, Hashable, Sendable {
        let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    private(set) var name: String
    private(set) var entries: [CustomPlaylistEntry]
    let createdAt: Date
    private(set) var updatedAt: Date

    init(
        id: ID = ID(),
        name: String,
        entries: [CustomPlaylistEntry] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func contains(mediaItem: LibraryMediaItem) -> Bool {
        entries.contains { entry in
            entry.media.hasSameMedia(as: mediaItem)
        }
    }

    fileprivate mutating func rename(to name: String, now: Date) {
        self.name = name
        updatedAt = now
    }

    fileprivate mutating func append(
        _ entries: [CustomPlaylistEntry],
        now: Date
    ) {
        guard !entries.isEmpty else {
            return
        }
        self.entries.append(contentsOf: entries)
        updatedAt = now
    }

    fileprivate mutating func attachAccessGrants(_ ids: [CustomPlaylistEntry.ID: UUID]) -> Bool {
        var changed = false
        for index in entries.indices {
            guard let id = ids[entries[index].id], entries[index].accessGrantID != id else { continue }
            entries[index].attachAccessGrant(id)
            changed = true
        }
        return changed
    }

    fileprivate mutating func relocateAccessRoots(
        _ migrations: [UUID: (sourcePath: String, destinationPath: String, kind: MediaSourceKind)]
    ) {
        for index in entries.indices {
            guard let grantID = entries[index].accessGrantID,
                  let migration = migrations[grantID] else { continue }
            entries[index].relocateAccessRoot(
                from: migration.sourcePath, to: migration.destinationPath, kind: migration.kind
            )
        }
    }

    fileprivate mutating func relocateLegacyAccessRoot(
        from sourcePath: String, to destinationPath: String, kind: MediaSourceKind
    ) {
        for index in entries.indices where entries[index].accessGrantID == nil
            && entries[index].media.mediaItemID.rootPath == sourcePath {
            entries[index].relocateAccessRoot(from: sourcePath, to: destinationPath, kind: kind)
        }
    }

    fileprivate mutating func updateResolvedItems(
        _ items: [CustomPlaylistEntry.ID: LibraryMediaItem]
    ) -> Bool {
        var changed = false
        for index in entries.indices {
            guard let item = items[entries[index].id] else { continue }
            let previous = entries[index]
            entries[index].update(using: item)
            changed = changed || entries[index] != previous
        }
        return changed
    }

    fileprivate mutating func remove(
        entryIDs: Set<CustomPlaylistEntry.ID>,
        now: Date
    ) -> Int {
        let originalCount = entries.count
        entries.removeAll { entryIDs.contains($0.id) }
        if entries.count != originalCount {
            updatedAt = now
        }
        return originalCount - entries.count
    }

    fileprivate mutating func move(
        entryID: CustomPlaylistEntry.ID,
        before destinationID: CustomPlaylistEntry.ID?,
        now: Date
    ) {
        guard destinationID != entryID else {
            return
        }
        guard let sourceIndex = entries.firstIndex(
            where: { $0.id == entryID }
        ) else {
            return
        }
        let destinationIndex: Int
        if let destinationID {
            guard let index = entries.firstIndex(
                where: { $0.id == destinationID }
            ) else { return }
            destinationIndex = index > sourceIndex ? index - 1 : index
        } else {
            destinationIndex = entries.count - 1
        }
        guard destinationIndex != sourceIndex else { return }
        let entry = entries.remove(at: sourceIndex)
        entries.insert(entry, at: destinationIndex)
        updatedAt = now
    }

    fileprivate mutating func reconcile(
        using index: MediaReferenceResolutionIndex,
        now: Date
    ) -> Bool {
        let previousReferences = entries.map(\.media)
        let resolvedItems = index.resolveReferences(entries.map(\.media))
        var proposedReferences = previousReferences
        for entryIndex in entries.indices {
            guard let item = resolvedItems[entryIndex] else {
                continue
            }
            proposedReferences[entryIndex].update(using: item)
        }

        let identityCounts = Dictionary(
            grouping: proposedReferences.compactMap(\.fileIdentity),
            by: { $0 }
        ).mapValues(\.count)
        for entryIndex in entries.indices {
            guard let item = resolvedItems[entryIndex],
                  let proposedIdentity = proposedReferences[entryIndex]
                    .fileIdentity,
                  identityCounts[proposedIdentity, default: 0] > 1,
                  previousReferences[entryIndex].fileIdentity
                    != proposedIdentity else {
                continue
            }
            proposedReferences[entryIndex] = previousReferences[entryIndex]
            proposedReferences[entryIndex].update(
                using: item,
                adoptingFileIdentity: false
            )
        }

        let didChange = proposedReferences != previousReferences
        if didChange {
            for entryIndex in entries.indices {
                entries[entryIndex] = CustomPlaylistEntry(
                    id: entries[entryIndex].id,
                    media: proposedReferences[entryIndex],
                    accessGrantID: entries[entryIndex].accessGrantID
                )
            }
            updatedAt = now
        }
        return didChange
    }
}

struct CustomPlaylistCollection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let empty = CustomPlaylistCollection(playlists: [])

    let schemaVersion: Int
    private(set) var playlists: [CustomPlaylist]
    private(set) var accessGrants: [CustomPlaylistMediaGrant]

    init(playlists: [CustomPlaylist], accessGrants: [CustomPlaylistMediaGrant] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.playlists = playlists
        self.accessGrants = accessGrants
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, playlists, accessGrants
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: values, debugDescription: "Unsupported playlist schema"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        playlists = try values.decode([CustomPlaylist].self, forKey: .playlists)
        accessGrants = try values.decodeIfPresent([CustomPlaylistMediaGrant].self, forKey: .accessGrants) ?? []
        guard accessGrants.count <= MediaImportPolicy.maximumActiveSourceCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .accessGrants, in: values, debugDescription: "Too many playlist access grants"
            )
        }
        removeUnreferencedAccessGrants()
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              playlists.count <= CustomPlaylistPolicy.maximumPlaylistCount,
              playlists.reduce(0, { $0 + $1.entries.count })
                <= CustomPlaylistPolicy.maximumTotalEntryCount else {
            return false
        }

        var playlistIDs: Set<CustomPlaylist.ID> = []
        guard accessGrants.count <= MediaImportPolicy.maximumActiveSourceCount else { return false }
        var grantIDs: Set<UUID> = []
        var grantPaths: Set<String> = []
        var bookmarkBytes = 0
        for grant in accessGrants {
            guard Self.isValidAccessGrant(grant), grantIDs.insert(grant.id).inserted,
                  grantPaths.insert(Self.accessGrantKey(grant)).inserted else { return false }
            bookmarkBytes += grant.bookmark.count
            guard bookmarkBytes <= CustomPlaylistPolicy.maximumFileByteCount else { return false }
        }
        var normalizedNames: Set<String> = []
        var allEntryIDs: Set<CustomPlaylistEntry.ID> = []
        for playlist in playlists {
            guard playlistIDs.insert(playlist.id).inserted,
                  playlist.entries.count
                    <= CustomPlaylistPolicy.maximumEntriesPerPlaylist,
                  let normalizedName = Self.normalizedName(playlist.name),
                  normalizedNames.insert(
                    Self.nameUniquenessKey(normalizedName)
                  ).inserted else {
                return false
            }

            var entryIDs: Set<CustomPlaylistEntry.ID> = []
            var mediaItemIDs: Set<LibraryMediaItem.ID> = []
            var fileIdentities: Set<MediaFileIdentity> = []
            for entry in playlist.entries {
                guard entryIDs.insert(entry.id).inserted,
                      allEntryIDs.insert(entry.id).inserted,
                      mediaItemIDs.insert(
                        entry.media.mediaItemID
                      ).inserted,
                      entry.media.isValid else {
                    return false
                }
                if let id = entry.accessGrantID, !grantIDs.contains(id) { return false }
                if let fileIdentity = entry.media.fileIdentity,
                   !fileIdentities.insert(fileIdentity).inserted {
                    return false
                }
            }
        }
        return true
    }

    func playlist(id: CustomPlaylist.ID) -> CustomPlaylist? {
        playlists.first { $0.id == id }
    }

    var allEntries: [CustomPlaylistEntry] { playlists.flatMap(\.entries) }

    mutating func removeUnreferencedAccessGrants() {
        let used = Set(playlists.flatMap { $0.entries.compactMap(\.accessGrantID) })
        accessGrants.removeAll { !used.contains($0.id) }
    }

    @discardableResult
    mutating func attachAccessGrants(
        _ grantsByItemID: [LibraryMediaItem.ID: CustomPlaylistMediaGrant],
        using index: MediaReferenceResolutionIndex
    ) throws -> Bool {
        var grants = accessGrants
        var updated = playlists
        var changed = false
        for playlistIndex in updated.indices {
            let entries = updated[playlistIndex].entries
            let items = index.resolveReferences(entries.map(\.media))
            var ids: [CustomPlaylistEntry.ID: UUID] = [:]
            for (entry, item) in zip(entries, items) where entry.accessGrantID == nil {
                guard let item, let grant = grantsByItemID[item.id] else { continue }
                ids[entry.id] = try Self.register(grant, in: &grants)
            }
            changed = updated[playlistIndex].attachAccessGrants(ids) || changed
        }
        changed = changed || grants != accessGrants
        if changed { playlists = updated; accessGrants = grants }
        return changed
    }

    @discardableResult
    mutating func installReauthorizedGrant(
        _ grant: CustomPlaylistMediaGrant, legacySourcePath: String
    ) throws -> Bool {
        let previous = accessGrants.first { $0.id == grant.id }
        guard previous?.kind == nil || previous?.kind == grant.kind else {
            throw CustomPlaylistMutationError.authorizationUnavailable
        }
        var grants = accessGrants
        let id = try Self.register(grant, in: &grants)
        var updated = playlists
        for index in updated.indices {
            // Capture assignments before moving legacy roots, while their
            // original source path is still available for exact matching.
            let assignments = Dictionary(uniqueKeysWithValues: updated[index].entries.compactMap { entry in
                if entry.accessGrantID == grant.id { return (entry.id, id) }
                guard entry.accessGrantID == nil,
                      entry.media.mediaItemID.rootPath == legacySourcePath else { return nil }
                return (entry.id, id)
            })
            if let previous {
                updated[index].relocateAccessRoots([
                    previous.id: (previous.sourcePath, grant.sourcePath, grant.kind)
                ])
            }
            updated[index].relocateLegacyAccessRoot(
                from: legacySourcePath, to: grant.sourcePath, kind: grant.kind
            )
            _ = updated[index].attachAccessGrants(assignments)
        }
        let changed = updated != playlists || grants != accessGrants
        playlists = updated
        accessGrants = grants
        removeUnreferencedAccessGrants()
        return changed
    }

    @discardableResult
    mutating func applyMediaResolution(_ resolution: CustomPlaylistMediaResolution) throws -> Bool {
        var grants = accessGrants
        var remapped: [UUID: UUID] = [:]
        var migrations: [UUID: (sourcePath: String, destinationPath: String, kind: MediaSourceKind)] = [:]
        let originals = Dictionary(uniqueKeysWithValues: accessGrants.map { ($0.id, $0) })
        for grant in resolution.refreshedGrants {
            guard let previous = originals[grant.id] else { continue }
            guard previous.kind == grant.kind else { throw CustomPlaylistMutationError.authorizationUnavailable }
            migrations[grant.id] = (previous.sourcePath, grant.sourcePath, grant.kind)
            remapped[grant.id] = try Self.register(grant, in: &grants)
        }
        var updated = playlists
        for index in updated.indices {
            updated[index].relocateAccessRoots(migrations)
            let ids = Dictionary(uniqueKeysWithValues: updated[index].entries.compactMap { entry in
                entry.accessGrantID.flatMap { remapped[$0] }.map { (entry.id, $0) }
            })
            _ = updated[index].attachAccessGrants(ids)
            _ = updated[index].updateResolvedItems(resolution.itemsByEntryID)
        }
        let changed = updated != playlists || grants != accessGrants
        playlists = updated
        accessGrants = grants
        removeUnreferencedAccessGrants()
        return changed
    }

    static func isValidAccessGrant(_ grant: CustomPlaylistMediaGrant) -> Bool {
        grant.sourcePath.hasPrefix("/") && !grant.sourcePath.utf8.contains(0)
            && grant.sourcePath.utf8.count <= CustomPlaylistPolicy.maximumFileByteCount
            && !grant.bookmark.isEmpty
            && grant.bookmark.count <= MediaImportPolicy.maximumBookmarkByteCount
    }

    private static func accessGrantKey(_ grant: CustomPlaylistMediaGrant) -> String {
        grant.kind.rawValue + ":" + URL(fileURLWithPath: grant.sourcePath).standardizedFileURL.path
    }

    private static func register(
        _ grant: CustomPlaylistMediaGrant, in grants: inout [CustomPlaylistMediaGrant]
    ) throws -> UUID {
        guard isValidAccessGrant(grant) else { throw CustomPlaylistMutationError.authorizationUnavailable }
        let key = accessGrantKey(grant)
        if let index = grants.firstIndex(where: { accessGrantKey($0) == key }) {
            try validateReplacement(grant, replacing: index, in: grants)
            let id = grants[index].id
            grants[index] = CustomPlaylistMediaGrant(
                id: id, sourcePath: grant.sourcePath, kind: grant.kind, bookmark: grant.bookmark
            )
            return id
        }
        if let index = grants.firstIndex(where: { $0.id == grant.id }) {
            try validateReplacement(grant, replacing: index, in: grants)
            grants[index] = grant
            return grant.id
        }
        guard grants.count < MediaImportPolicy.maximumActiveSourceCount,
              grants.reduce(0, { $0 + $1.bookmark.count }) + grant.bookmark.count
                <= CustomPlaylistPolicy.maximumFileByteCount else {
            throw CustomPlaylistMutationError.authorizationUnavailable
        }
        grants.append(grant)
        return grant.id
    }

    private static func validateReplacement(
        _ grant: CustomPlaylistMediaGrant, replacing index: Int,
        in grants: [CustomPlaylistMediaGrant]
    ) throws {
        let bytes = grants.reduce(0) { $0 + $1.bookmark.count }
            - grants[index].bookmark.count + grant.bookmark.count
        guard bytes <= CustomPlaylistPolicy.maximumFileByteCount else {
            throw CustomPlaylistMutationError.authorizationUnavailable
        }
    }

    @discardableResult
    mutating func createPlaylist(
        named requestedName: String,
        now: Date = Date()
    ) throws -> CustomPlaylist.ID {
        guard playlists.count < CustomPlaylistPolicy.maximumPlaylistCount else {
            throw CustomPlaylistMutationError.playlistLimitReached
        }
        let name = try availableName(requestedName)
        let playlist = CustomPlaylist(
            name: name,
            createdAt: now,
            updatedAt: now
        )
        playlists.append(playlist)
        return playlist.id
    }

    mutating func renamePlaylist(
        id: CustomPlaylist.ID,
        to requestedName: String,
        now: Date = Date()
    ) throws {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            throw CustomPlaylistMutationError.playlistNotFound
        }
        let name = try availableName(requestedName, excluding: id)
        playlists[index].rename(to: name, now: now)
    }

    @discardableResult
    mutating func removePlaylist(id: CustomPlaylist.ID) -> Bool {
        let originalCount = playlists.count
        playlists.removeAll { $0.id == id }
        removeUnreferencedAccessGrants()
        return playlists.count != originalCount
    }

    @discardableResult
    mutating func add(
        items: [LibraryMediaItem],
        to playlistID: CustomPlaylist.ID,
        now: Date = Date(),
        grantsByItemID: [LibraryMediaItem.ID: CustomPlaylistMediaGrant] = [:]
    ) throws -> Int {
        guard let playlistIndex = playlists.firstIndex(
            where: { $0.id == playlistID }
        ) else {
            throw CustomPlaylistMutationError.playlistNotFound
        }

        let playlist = playlists[playlistIndex]
        let remainingPlaylistCapacity =
            CustomPlaylistPolicy.maximumEntriesPerPlaylist
            - playlist.entries.count
        let totalEntryCount = playlists.reduce(0) { $0 + $1.entries.count }
        let remainingCollectionCapacity =
            CustomPlaylistPolicy.maximumTotalEntryCount - totalEntryCount
        let remainingCapacity = min(
            remainingPlaylistCapacity,
            remainingCollectionCapacity
        )
        var acceptedItems: [LibraryMediaItem] = []
        acceptedItems.reserveCapacity(min(items.count, remainingCapacity))
        var knownItemIDs = Set(playlist.entries.map(\.media.mediaItemID))
        var knownFileIdentities = Set(
            playlist.entries.compactMap(\.media.fileIdentity)
        )

        for item in items {
            guard !knownItemIDs.contains(item.id),
                  item.fileIdentity.map({
                      !knownFileIdentities.contains($0)
                  }) ?? true else {
                continue
            }
            guard acceptedItems.count < remainingCapacity else {
                throw CustomPlaylistMutationError.entryLimitReached
            }
            acceptedItems.append(item)
            knownItemIDs.insert(item.id)
            if let fileIdentity = item.fileIdentity {
                knownFileIdentities.insert(fileIdentity)
            }
        }

        var grants = accessGrants
        let entries = try acceptedItems.map { item in
            let grantID = try grantsByItemID[item.id].map { try Self.register($0, in: &grants) }
            return CustomPlaylistEntry(media: MediaReference(item: item), accessGrantID: grantID)
        }
        playlists[playlistIndex].append(entries, now: now)
        accessGrants = grants
        return acceptedItems.count
    }

    mutating func removeEntry(
        _ entryID: CustomPlaylistEntry.ID,
        from playlistID: CustomPlaylist.ID,
        now: Date = Date()
    ) throws {
        try removeEntries([entryID], from: playlistID, now: now)
    }

    @discardableResult
    mutating func removeEntries(
        _ entryIDs: Set<CustomPlaylistEntry.ID>,
        from playlistID: CustomPlaylist.ID,
        now: Date = Date()
    ) throws -> Int {
        guard let playlistIndex = playlists.firstIndex(
            where: { $0.id == playlistID }
        ) else {
            throw CustomPlaylistMutationError.playlistNotFound
        }
        let count = playlists[playlistIndex].remove(entryIDs: entryIDs, now: now)
        removeUnreferencedAccessGrants()
        return count
    }

    mutating func moveEntry(
        _ entryID: CustomPlaylistEntry.ID,
        before destinationID: CustomPlaylistEntry.ID?,
        in playlistID: CustomPlaylist.ID,
        now: Date = Date()
    ) throws {
        guard let playlistIndex = playlists.firstIndex(
            where: { $0.id == playlistID }
        ) else {
            throw CustomPlaylistMutationError.playlistNotFound
        }
        playlists[playlistIndex].move(
            entryID: entryID,
            before: destinationID,
            now: now
        )
    }

    @discardableResult
    mutating func reconcile(
        using items: [LibraryMediaItem],
        now: Date = Date()
    ) -> Bool {
        guard playlists.contains(where: { !$0.entries.isEmpty }) else { return false }
        return reconcile(using: MediaReferenceResolutionIndex(items: items), now: now)
    }

    @discardableResult
    mutating func reconcile(
        using index: MediaReferenceResolutionIndex,
        now: Date = Date()
    ) -> Bool {
        var didChange = false
        for playlistIndex in playlists.indices {
            didChange = playlists[playlistIndex].reconcile(
                using: index,
                now: now
            ) || didChange
        }
        return didChange
    }

    mutating func reconcileCancellable(
        using index: MediaReferenceResolutionIndex,
        now: Date = Date()
    ) throws -> Bool {
        var didChange = false
        for playlistIndex in playlists.indices {
            try Task.checkCancellation()
            didChange = playlists[playlistIndex].reconcile(
                using: index,
                now: now
            ) || didChange
        }
        try Task.checkCancellation()
        return didChange
    }

    func resolvedItems(
        in playlistID: CustomPlaylist.ID,
        using items: [LibraryMediaItem]
    ) -> [LibraryMediaItem] {
        guard let playlist = playlist(id: playlistID) else {
            return []
        }
        let index = MediaReferenceResolutionIndex(items: items)
        return index.resolveReferences(
            playlist.entries.map(\.media)
        ).compactMap { $0 }
    }

    func resolvedItemsByEntryID(
        in playlistID: CustomPlaylist.ID,
        using items: [LibraryMediaItem]
    ) -> [CustomPlaylistEntry.ID: LibraryMediaItem] {
        guard let playlist = playlist(id: playlistID) else {
            return [:]
        }
        let resolvedItems = MediaReferenceResolutionIndex(items: items)
            .resolveReferences(playlist.entries.map(\.media))
        var itemsByEntryID: [
            CustomPlaylistEntry.ID: LibraryMediaItem
        ] = [:]
        itemsByEntryID.reserveCapacity(resolvedItems.count)
        for (entry, item) in zip(playlist.entries, resolvedItems) {
            if let item {
                itemsByEntryID[entry.id] = item
            }
        }
        return itemsByEntryID
    }

    private func availableName(
        _ requestedName: String,
        excluding excludedID: CustomPlaylist.ID? = nil
    ) throws -> String {
        guard let name = Self.normalizedName(requestedName) else {
            throw CustomPlaylistMutationError.invalidName
        }
        let uniquenessKey = Self.nameUniquenessKey(name)
        guard !playlists.contains(where: {
            $0.id != excludedID
                && Self.nameUniquenessKey($0.name) == uniquenessKey
        }) else {
            throw CustomPlaylistMutationError.duplicateName
        }
        return name
    }

    private static func normalizedName(_ name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count
                <= CustomPlaylistPolicy.maximumNameByteCount else {
            return nil
        }
        return normalized
    }

    private static func nameUniquenessKey(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum CustomPlaylistStoreError: Error, Equatable, Sendable {
    case invalidCollection
    case fileTooLarge(maximumByteCount: Int, observedByteCount: Int)
}

protocol CustomPlaylistStoring: Sendable {
    func load() async throws -> CustomPlaylistCollection
    func save(_ collection: CustomPlaylistCollection) async throws
}
