import Combine
import Foundation

/// Keeps named-playlist persistence independent from playback while ensuring
/// an active playlist queue follows edits and media-library rescans.
@MainActor
final class CustomPlaylistPlaybackBridge {
    private struct QueueSynchronizationKey: Equatable {
        let playlistID: CustomPlaylist.ID
        let entries: [CustomPlaylistEntry]
        let mediaResolutionRevision: UInt64
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
    private var latestResolutionItems: [LibraryMediaItem]
    private var latestResolutionRevision: UInt64
    private var latestResolutionEntryItems: [CustomPlaylistEntry.ID: LibraryMediaItem] = [:]
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
        latestResolutionItems = playlists.resolutionItems
        latestResolutionRevision = playlists.resolutionRevision

        library.customPlaylistItemsProvider = {
            [weak playlists] playlistID in
            guard let playlists,
                  playlists.isReady,
                  playlists.collection.playlist(id: playlistID) != nil else {
                return nil
            }
            return playlists.resolvedItems(in: playlistID)
        }
        library.customPlaylistHasUnresolvedItemsProvider = { [weak playlists] playlistID in
            guard let playlists, let playlist = playlists.collection.playlist(id: playlistID) else {
                return false
            }
            return playlists.resolvedItems(in: playlistID).count < playlist.entries.count
        }
        library.prepareForPlaylistSourceRemoval = { [weak playlists] root in
            guard let playlists else { return true }
            return await playlists.prepareForSourceRemoval(root)
        }
        library.retainedPlaylistItemsProvider = { [weak playlists] in
            playlists?.resolutionItems.filter { $0.accessLease != nil } ?? []
        }

        playlists.collectionPublisher
            .sink { [weak self] collection in
                self?.playlistCollectionDidChange(collection)
            }
            .store(in: &cancellables)

        playlists.resolutionPublisher
            .sink { [weak self] snapshot in
                guard let self else { return }
                latestResolutionItems = snapshot.items
                latestResolutionRevision = snapshot.revision
                latestResolutionEntryItems = snapshot.itemsByEntryID
                self.library?.updatePlaylistThumbnailAccess(using: snapshot.items)
                synchronizeActiveQueueIfReady()
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

        library.$sourceAccessState
            .sink { [weak playlists] _ in
                playlists?.refreshAccessGrantsFromSources()
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
        await playlists.waitForMediaResolution()
        latestResolutionItems = playlists.resolutionItems
        latestResolutionRevision = playlists.resolutionRevision
        synchronizeActiveQueueIfReady()
    }

    func shutdown() async {
        cancellables.removeAll()
        library?.customPlaylistItemsProvider = nil
        library?.customPlaylistHasUnresolvedItemsProvider = nil
        library?.prepareForPlaylistSourceRemoval = nil
        library?.retainedPlaylistItemsProvider = nil
        synchronizedQueueKey = nil
        synchronizedQueueStructureRevision = nil
        latestCollection = .empty
        latestLibraryItems.removeAll()
        latestResolutionIndex = nil
        latestResolutionItems.removeAll()
        latestResolutionEntryItems.removeAll()
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
            items: latestResolutionItems,
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
            items: latestResolutionItems,
            scanState: latestScanState,
            library: library,
            previousCollection: previousCollection
        )
    }

    private func synchronizeActiveQueue(
        collection: CustomPlaylistCollection,
        items: [LibraryMediaItem],
        scanState: MediaLibraryScanState,
        library: MediaLibraryCoordinator,
        previousCollection: CustomPlaylistCollection? = nil
    ) {
        guard playlists.usesIndependentMediaAccess || scanState == .ready else { return }
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
            mediaResolutionRevision: latestResolutionRevision
        )
        guard synchronizedQueueKey != key
            || synchronizedQueueStructureRevision != library.queueStructureRevision else {
            return
        }
        let playlistItems: [LibraryMediaItem]
        let queueContext = library.capturePlaybackContext()
        if playlists.usesIndependentMediaAccess {
            let previousEntries = (previousCollection ?? collection)
                .playlist(id: playlistID)?.entries ?? []
            let previousMediaByEntryID = Dictionary(uniqueKeysWithValues:
                previousEntries.map { ($0.id, $0.media.mediaItemID) }
            )
            // A temporary resolution failure must not revoke an active owned
            // queue item. Match retained representations by the previous entry
            // identity so newly added, unresolved entries cannot inherit one.
            playlistItems = playlist.entries.compactMap { entry in
                if let resolved = latestResolutionEntryItems[entry.id] { return resolved }
                guard let previousID = previousMediaByEntryID[entry.id],
                      let retained = queueContext?.queueItemsByID[previousID],
                      retained.accessLease != nil else { return nil }
                return retained
            }
        } else {
            playlistItems = playlists.resolvedItems(
                in: playlistID, collection: collection, using: items,
                itemsRevision: latestResolutionRevision
            )
        }
        // Unchanged owned items need no synchronization while unavailable.
        // Actual removals and reorders still install their authoritative order.
        if playlists.usesIndependentMediaAccess,
           playlist.entries.allSatisfy({ latestResolutionEntryItems[$0.id] == nil }),
           playlistItems.map(\.id) == queueContext?.queueSnapshot.items { return }
        synchronizedQueueKey = key
        activeQueueSynchronizationCount &+= 1
        library.synchronizeCustomPlaylistQueue(
            playlistID: playlistID,
            playlistItems: playlistItems
        )
        synchronizedQueueStructureRevision = library.queueStructureRevision
    }
}
