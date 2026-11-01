import Foundation

enum MediaBrowserLayout: String, CaseIterable, Sendable {
    case list
    case grid
}

/// Guards transient browser selection against observed file replacement or edits.
/// This is neither persistent media identity nor evidence for resolving other files.
struct MediaBrowserItemIdentity: Hashable {
    let mediaID: LibraryMediaItem.ID
    let fileIdentity: MediaFileIdentity?
    let fileSize: Int64
    let modificationDate: Date?

    init(_ item: LibraryMediaItem) {
        mediaID = item.id
        fileIdentity = item.fileIdentity
        fileSize = item.fileSize
        modificationDate = item.modificationDate
    }
}

/// Transient selection belongs to a browser view, never to its playback queue.
/// Callers retain only IDs in the current result when search or library data changes.
struct MediaBrowserSelection<ID: Hashable> {
    private(set) var ids: Set<ID> = []
    private(set) var isSelecting = false
    private(set) var revision: UInt64 = 0

    mutating func begin() {
        update(ids: [], isSelecting: true)
    }

    mutating func end() {
        update(ids: [], isSelecting: false)
    }

    mutating func clear() {
        update(ids: [], isSelecting: isSelecting)
    }

    mutating func toggle(_ id: ID) {
        guard isSelecting else { return }
        var nextIDs = ids
        if !nextIDs.insert(id).inserted {
            nextIDs.remove(id)
        }
        update(ids: nextIDs, isSelecting: true)
    }

    /// Replaces selection with the current visible result, including an empty result.
    mutating func selectAll(_ ids: [ID]) {
        guard isSelecting else { return }
        update(ids: Set(ids), isSelecting: true)
    }

    mutating func retain(_ ids: Set<ID>) {
        update(ids: self.ids.intersection(ids), isSelecting: isSelecting)
    }

    private mutating func update(ids: Set<ID>, isSelecting: Bool) {
        guard self.ids != ids || self.isSelecting != isSelecting else { return }
        self.ids = ids
        self.isSelecting = isSelecting
        revision &+= 1
    }
}
