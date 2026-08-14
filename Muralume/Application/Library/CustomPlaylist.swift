import Foundation

enum CustomPlaylistPolicy {
    static let maximumPlaylistCount = 256
    static let maximumEntriesPerPlaylist = 10_000
    static let maximumTotalEntryCount = 20_000
    static let maximumNameByteCount = 256
    static let maximumFileByteCount = 16 * 1_024 * 1_024
}

enum CustomPlaylistMutationError: Error, Equatable, Sendable {
    case invalidName
    case duplicateName
    case playlistNotFound
    case playlistLimitReached
    case entryLimitReached
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

    init(id: ID = ID(), media: MediaReference) {
        self.id = id
        self.media = media
    }

    mutating func update(using item: LibraryMediaItem) {
        media.update(using: item)
    }
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

    fileprivate mutating func remove(
        entryID: CustomPlaylistEntry.ID,
        now: Date
    ) {
        let originalCount = entries.count
        entries.removeAll { $0.id == entryID }
        if entries.count != originalCount {
            updatedAt = now
        }
    }

    fileprivate mutating func move(
        entryID: CustomPlaylistEntry.ID,
        before destinationID: CustomPlaylistEntry.ID?,
        now: Date
    ) {
        guard destinationID != entryID else {
            return
        }
        if let destinationID,
           !entries.contains(where: { $0.id == destinationID }) {
            return
        }
        guard let sourceIndex = entries.firstIndex(
            where: { $0.id == entryID }
        ) else {
            return
        }
        let originalEntryIDs = entries.map(\.id)
        let entry = entries.remove(at: sourceIndex)
        let destinationIndex = destinationID.flatMap { destinationID in
            entries.firstIndex { $0.id == destinationID }
        } ?? entries.endIndex
        entries.insert(entry, at: destinationIndex)
        if entries.map(\.id) != originalEntryIDs {
            updatedAt = now
        }
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
                    media: proposedReferences[entryIndex]
                )
            }
            updatedAt = now
        }
        return didChange
    }
}

struct CustomPlaylistCollection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let empty = CustomPlaylistCollection(playlists: [])

    let schemaVersion: Int
    private(set) var playlists: [CustomPlaylist]

    init(playlists: [CustomPlaylist]) {
        schemaVersion = Self.currentSchemaVersion
        self.playlists = playlists
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              playlists.count <= CustomPlaylistPolicy.maximumPlaylistCount,
              playlists.reduce(0, { $0 + $1.entries.count })
                <= CustomPlaylistPolicy.maximumTotalEntryCount else {
            return false
        }

        var playlistIDs: Set<CustomPlaylist.ID> = []
        var normalizedNames: Set<String> = []
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
                      mediaItemIDs.insert(
                        entry.media.mediaItemID
                      ).inserted,
                      entry.media.isValid else {
                    return false
                }
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
        return playlists.count != originalCount
    }

    @discardableResult
    mutating func add(
        items: [LibraryMediaItem],
        to playlistID: CustomPlaylist.ID,
        now: Date = Date()
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
        guard remainingCapacity > 0 || items.isEmpty else {
            throw CustomPlaylistMutationError.entryLimitReached
        }

        var acceptedItems: [LibraryMediaItem] = []
        acceptedItems.reserveCapacity(min(items.count, remainingCapacity))
        var knownReferences = playlist.entries.map(\.media)

        for item in items {
            guard !knownReferences.contains(where: {
                $0.hasSameMedia(as: item)
            }) else {
                continue
            }
            guard acceptedItems.count < remainingCapacity else {
                throw CustomPlaylistMutationError.entryLimitReached
            }
            acceptedItems.append(item)
            knownReferences.append(MediaReference(item: item))
        }

        playlists[playlistIndex].append(
            acceptedItems.map {
                CustomPlaylistEntry(media: MediaReference(item: $0))
            },
            now: now
        )
        return acceptedItems.count
    }

    mutating func removeEntry(
        _ entryID: CustomPlaylistEntry.ID,
        from playlistID: CustomPlaylist.ID,
        now: Date = Date()
    ) throws {
        guard let playlistIndex = playlists.firstIndex(
            where: { $0.id == playlistID }
        ) else {
            throw CustomPlaylistMutationError.playlistNotFound
        }
        playlists[playlistIndex].remove(entryID: entryID, now: now)
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
        let index = MediaReferenceResolutionIndex(items: items)
        var didChange = false
        for playlistIndex in playlists.indices {
            didChange = playlists[playlistIndex].reconcile(
                using: index,
                now: now
            ) || didChange
        }
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
