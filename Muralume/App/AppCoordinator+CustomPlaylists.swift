import Foundation

extension AppCoordinator {
    func restoreLibrarySidebarForActivePlaybackCollection() {
        let destination: LibrarySidebarDestination
        if !library.isExternalPlaybackContext,
           case let .customPlaylist(playlistID) =
               library.activePlaybackCollection,
           playlists.isReady,
           playlists.collection.playlist(id: playlistID) != nil {
            destination = .playlist(playlistID)
        } else {
            destination = .mediaLibrary
        }
        playerChrome.restoreLibrarySidebarDestination(destination)
    }

    func addLibraryItem(
        _ item: LibraryMediaItem,
        to playlistID: CustomPlaylist.ID
    ) {
        _ = try? playlists.add(items: [item], to: playlistID)
    }

    func playCustomPlaylistItem(
        _ item: LibraryMediaItem,
        playlistID: CustomPlaylist.ID
    ) {
        guard playlists.collection.playlist(id: playlistID) != nil else {
            return
        }
        let playlistItems = playlists.resolvedItems(
            in: playlistID,
            using: library.items
        )
        guard playlistItems.contains(where: { $0.id == item.id }) else {
            return
        }
        cancelSourceAccessRetry()
        clearDynamicDesktopReturnContext()
        library.playCustomPlaylistItem(
            item,
            playlistID: playlistID,
            playlistItems: playlistItems
        )
    }
}
