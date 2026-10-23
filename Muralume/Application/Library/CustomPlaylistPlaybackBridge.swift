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
    private var latestLibraryItemsRevision: UInt64
    private var latestScanState: MediaLibraryScanState

    init(
        playlists: CustomPlaylistController,
        library: MediaLibraryCoordinator
    ) {
        self.playlists = playlists
        self.library = library
        latestLibraryItems = library.items
        latestLibraryItemsRevision = library.itemsRevision
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
                using: library.items,
                itemsRevision: library.itemsRevision
            )
        }

        playlists.collectionPublisher
            .sink { [weak self] collection in
                self?.playlistCollectionDidChange(collection)
            }
            .store(in: &cancellables)

        library.itemsRevisionPublisher
            .sink { [weak self] snapshot in
                self?.libraryItemsDidChange(
                    using: snapshot.items,
                    revision: snapshot.revision
                )
            }
            .store(in: &cancellables)

        library.$scanState
            .sink { [weak self] scanState in
                guard let self else { return }
                latestScanState = scanState
                synchronizeActiveQueueIfReady()
            }
            .store(in: &cancellables)
    }

    func startAndWait() async {
        await playlists.startAndWait()
        guard let library else {
            return
        }
        latestScanState = library.scanState
        libraryItemsDidChange(
            using: library.items,
            revision: library.itemsRevision
        )
    }

    func shutdown() async {
        cancellables.removeAll()
        library?.customPlaylistItemsProvider = nil
        await playlists.shutdown()
    }

    private func libraryItemsDidChange(
        using items: [LibraryMediaItem],
        revision: UInt64
    ) {
        latestLibraryItems = items
        latestLibraryItemsRevision = revision
        guard playlists.isReady else { return }
        playlists.updateAvailableItems(items, itemsRevision: revision)
        synchronizeActiveQueueIfReady()
    }

    private func synchronizeActiveQueueIfReady() {
        guard playlists.isReady, let library else { return }
        synchronizeActiveQueue(
            collection: playlists.collection,
            items: latestLibraryItems,
            scanState: latestScanState,
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
            playlistItems: playlists.resolvedItems(
                in: playlistID,
                collection: collection,
                using: items,
                itemsRevision: latestLibraryItemsRevision
            )
        )
    }
}
