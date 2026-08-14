import Combine
import Foundation

enum LibrarySidebarDestination: Equatable, Hashable, Sendable {
    case mediaLibrary
    case playlists
    case playlist(CustomPlaylist.ID)
    case playQueue

    var supportsSearch: Bool {
        switch self {
        case .mediaLibrary, .playlist:
            true
        case .playlists, .playQueue:
            false
        }
    }
}

/// Owns navigation and transient search state independently from the sidebar
/// view so temporarily replacing or hiding the panel does not discard it.
@MainActor
final class LibrarySidebarController: ObservableObject {
    @Published private(set) var destination: LibrarySidebarDestination
    @Published private(set) var query: String
    @Published private(set) var searchFocusRequest: UInt64 = 0
    @Published private(set) var playbackQueueFocusRequest: UInt64 = 0
    private var nextSearchFocusRequest: UInt64 = 0

    init(
        destination: LibrarySidebarDestination = .mediaLibrary,
        query: String = ""
    ) {
        self.destination = destination
        self.query = destination.supportsSearch ? query : ""
    }

    func updateQuery(_ query: String) {
        guard destination.supportsSearch,
              self.query != query else {
            return
        }
        self.query = query
    }

    func selectDestination(_ destination: LibrarySidebarDestination) {
        let destinationChanged = self.destination != destination
        if destinationChanged {
            self.destination = destination
            clearQuery()
            // A focus token belongs to the collection that received it. A
            // normal navigation must not make a newly created search field
            // consume an old request from another collection.
            searchFocusRequest = 0
        }

        if destination == .playQueue {
            playbackQueueFocusRequest &+= 1
        }
    }

    /// Focuses search in the current searchable collection. Destinations that
    /// do not expose media search first return to the media library.
    func requestSearch() {
        switch destination {
        case .mediaLibrary, .playlist:
            break
        case .playlists, .playQueue:
            destination = .mediaLibrary
            clearQuery()
        }
        nextSearchFocusRequest &+= 1
        if nextSearchFocusRequest == 0 {
            nextSearchFocusRequest = 1
        }
        searchFocusRequest = nextSearchFocusRequest
    }

    /// A focus request is edge-triggered. Clearing the token after the field
    /// handles it prevents a later sidebar reconstruction from stealing focus.
    func consumeSearchFocusRequest(_ request: UInt64) {
        guard request > 0, searchFocusRequest == request else {
            return
        }
        searchFocusRequest = 0
    }

    /// Keeps navigation valid after a playlist is removed from the store.
    func playlistDidDelete(_ playlistID: CustomPlaylist.ID) {
        guard destination == .playlist(playlistID) else {
            return
        }
        destination = .playlists
        clearQuery()
        searchFocusRequest = 0
    }

    private func clearQuery() {
        guard !query.isEmpty else {
            return
        }
        query = ""
    }
}
