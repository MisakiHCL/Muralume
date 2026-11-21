import Foundation

extension AppCoordinator {
    var desktopQueueMenuState: DesktopQueueMenuState {
        let choices = playlists.playlists.map { playlist in
            let target = PlaybackCollection.customPlaylist(playlist.id)
            let playable = playlists.isReady && playlists.containsResolvedItem(in: playlist) {
                library.canStartQueue(with: $0, in: target)
            }
            return DesktopQueueMenuState.Playlist(id: playlist.id, name: playlist.name, isPlayable: playable)
        }
        return DesktopQueueMenuState(
            isLibraryPlayable: library.items.contains { library.canStartQueue(with: $0, in: .mediaLibrary) },
            playlists: choices,
            selection: selectedDesktopQueue
        )
    }

    private var selectedDesktopQueue: PlaybackCollection? {
        guard library.hasActiveQueue, !library.isExternalPlaybackContext,
              library.activePlaybackCollection != .fixed else { return nil }
        return library.activePlaybackCollection
    }

    func selectDesktopQueue(_ collection: PlaybackCollection) {
        guard selectedDesktopQueue != collection else { return }
        let items: [LibraryMediaItem]
        switch collection {
        case .mediaLibrary:
            items = library.items
        case let .customPlaylist(id):
            guard playlists.isReady else { return }
            items = playlists.resolvedItems(in: id)
        case .fixed:
            return
        }
        guard let first = items.first(where: { library.canStartQueue(with: $0, in: collection) }) else { return }

        cancelSourceAccessRetry()
        clearDynamicDesktopReturnContext()
        switch collection {
        case .mediaLibrary:
            library.playLibraryItem(first, startingNewQueue: true)
        case let .customPlaylist(id):
            library.playCustomPlaylistItem(first, playlistID: id, playlistItems: items, startingNewQueue: true)
        case .fixed:
            break
        }
    }

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
        let playlistItems = playlists.resolvedItems(in: playlistID)
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
