import Combine
import Foundation

/// Keeps named-playlist persistence independent from playback while ensuring
/// an active playlist queue follows edits and media-library rescans.
@MainActor
final class CustomPlaylistPlaybackBridge {
    private let playlists: CustomPlaylistController
    private weak var library: MediaLibraryCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    private var latestLibraryItems: [LibraryMediaItem]
    private var latestScanState: MediaLibraryScanState

    init(
        playlists: CustomPlaylistController,
        library: MediaLibraryCoordinator
    ) {
        self.playlists = playlists
        self.library = library
        latestLibraryItems = library.items
        latestScanState = library.scanState

        library.customPlaylistItemsProvider = {
            [weak playlists, weak library] playlistID in
            guard let playlists,
                  playlists.isReady,
                  let library,
                  playlists.collection.playlist(id: playlistID) != nil else {
                return nil
            }
            return playlists.resolvedItems(
                in: playlistID,
                using: library.items
            )
        }

        playlists.collectionPublisher
            .sink { [weak self] collection in
                self?.playlistCollectionDidChange(collection)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            library.itemsPublisher,
            library.$scanState
        )
            .sink { [weak self] items, scanState in
                self?.libraryDidChange(
                    using: items,
                    scanState: scanState
                )
            }
            .store(in: &cancellables)
    }

    func startAndWait() async {
        await playlists.startAndWait()
        guard let library else {
            return
        }
        libraryDidChange(
            using: library.items,
            scanState: library.scanState
        )
    }

    func shutdown() async {
        cancellables.removeAll()
        library?.customPlaylistItemsProvider = nil
        await playlists.shutdown()
    }

    private func libraryDidChange(
        using items: [LibraryMediaItem],
        scanState: MediaLibraryScanState
    ) {
        latestLibraryItems = items
        latestScanState = scanState
        guard playlists.isReady, let library else {
            return
        }
        playlists.updateAvailableItems(items)
        synchronizeActiveQueue(
            collection: playlists.collection,
            items: items,
            scanState: scanState,
            library: library
        )
    }

    private func playlistCollectionDidChange(
        _ collection: CustomPlaylistCollection
    ) {
        guard playlists.isReady, let library else {
            return
        }
        synchronizeActiveQueue(
            collection: collection,
            items: latestLibraryItems,
            scanState: latestScanState,
            library: library
        )
    }

    private func synchronizeActiveQueue(
        collection: CustomPlaylistCollection,
        items: [LibraryMediaItem],
        scanState: MediaLibraryScanState,
        library: MediaLibraryCoordinator
    ) {
        guard scanState == .ready else {
            return
        }

        guard case let .customPlaylist(playlistID) =
            library.activePlaybackCollection else {
            return
        }
        guard collection.playlist(id: playlistID) != nil else {
            library.detachCustomPlaylistQueue(playlistID: playlistID)
            return
        }
        library.synchronizeCustomPlaylistQueue(
            playlistID: playlistID,
            playlistItems: collection.resolvedItems(
                in: playlistID,
                using: items
            )
        )
    }
}
