import Combine
import Foundation

/// Keeps named-playlist persistence independent from playback while ensuring
/// an active playlist queue follows edits and media-library rescans.
@MainActor
final class CustomPlaylistPlaybackBridge {
    private struct QueueSynchronizationKey: Equatable {
        let playlistID: CustomPlaylist.ID
        let entries: [CustomPlaylistEntry]
        let libraryContentRevision: UInt64
    }

    private let playlists: CustomPlaylistController
    private weak var library: MediaLibraryCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    private var latestLibraryItems: [LibraryMediaItem]
    private var latestLibraryItemsRevision: UInt64
    private var latestLibraryContentRevision: UInt64
    private var latestResolutionIndex: MediaReferenceResolutionIndex?
    private var latestScanState: MediaLibraryScanState
    private var latestCollection: CustomPlaylistCollection
    // Retain at most one active playlist. Names and timestamps are deliberately
    // excluded: only its media sequence and library availability affect playback.
    private var synchronizedQueueKey: QueueSynchronizationKey?
    private var synchronizedQueueStructureRevision: UInt64?
    private(set) var activeQueueSynchronizationCount = 0

    init(
        playlists: CustomPlaylistController,
        library: MediaLibraryCoordinator
    ) {
        self.playlists = playlists
        self.library = library
        latestLibraryItems = library.items
        latestLibraryItemsRevision = library.itemsRevision
        latestLibraryContentRevision = library.itemsContentRevision
        latestResolutionIndex = library.mediaReferenceResolutionIndex
        latestScanState = library.scanState
        latestCollection = playlists.collection

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

        library.itemsContentRevisionPublisher
            .sink { [weak self] snapshot in
                self?.libraryItemsDidChange(
                    using: snapshot.items,
                    revision: snapshot.revision,
                    contentRevision: snapshot.contentRevision,
                    resolutionIndex: snapshot.resolutionIndex
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
            using: latestLibraryItems,
            revision: latestLibraryItemsRevision,
            contentRevision: latestLibraryContentRevision,
            resolutionIndex: latestResolutionIndex
        )
        await playlists.waitForLibraryReconciliation()
        synchronizeActiveQueueIfReady()
    }

    func shutdown() async {
        cancellables.removeAll()
        library?.customPlaylistItemsProvider = nil
        synchronizedQueueKey = nil
        synchronizedQueueStructureRevision = nil
        latestCollection = .empty
        latestLibraryItems.removeAll()
        latestResolutionIndex = nil
        await playlists.shutdown()
    }

    private func libraryItemsDidChange(
        using items: [LibraryMediaItem],
        revision: UInt64,
        contentRevision: UInt64,
        resolutionIndex: MediaReferenceResolutionIndex?
    ) {
        let contentDidChange = latestLibraryContentRevision != contentRevision
        latestLibraryItems = items
        latestLibraryItemsRevision = revision
        latestLibraryContentRevision = contentRevision
        latestResolutionIndex = resolutionIndex
        guard playlists.isReady else { return }
        playlists.updateAvailableItems(
            items,
            itemsRevision: revision,
            contentRevision: contentRevision,
            resolutionIndex: resolutionIndex
        )
        if contentDidChange { synchronizeActiveQueueIfReady() }
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
        let previousCollection = latestCollection
        latestCollection = collection
        guard playlists.isReady, let library else {
            return
        }
        // @Published delivers the incoming snapshot before the controller's
        // current value changes. Compare those snapshots, including the first
        // edit after playback starts, rather than reading controller.collection.
        if case let .customPlaylist(playlistID) = library.activePlaybackCollection,
           let previous = previousCollection.playlist(id: playlistID),
           let incoming = collection.playlist(id: playlistID),
           previous.entries == incoming.entries {
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
            synchronizedQueueKey = nil
            return
        }
        guard let playlist = collection.playlist(id: playlistID) else {
            synchronizedQueueKey = nil
            library.detachCustomPlaylistQueue(playlistID: playlistID)
            return
        }
        let key = QueueSynchronizationKey(
            playlistID: playlistID,
            entries: playlist.entries,
            libraryContentRevision: latestLibraryContentRevision
        )
        guard synchronizedQueueKey != key
            || synchronizedQueueStructureRevision != library.queueStructureRevision else {
            return
        }
        synchronizedQueueKey = key
        activeQueueSynchronizationCount &+= 1
        library.synchronizeCustomPlaylistQueue(
            playlistID: playlistID,
            playlistItems: playlists.resolvedItems(
                in: playlistID,
                collection: collection,
                using: items,
                itemsRevision: latestLibraryItemsRevision
            )
        )
        synchronizedQueueStructureRevision = library.queueStructureRevision
    }
}
