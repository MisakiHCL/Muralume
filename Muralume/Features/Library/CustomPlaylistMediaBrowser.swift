import SwiftUI

struct CustomPlaylistMediaBrowser: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playlists: CustomPlaylistController
    @Binding var selection: MediaBrowserSelection<CustomPlaylistEntry.ID>
    let layout: MediaBrowserLayout
    let playlist: CustomPlaylist
    let projection: CustomPlaylistDetailProjection
    let contentRevision: UInt64
    let scrollToTopRequest: UInt64?
    let isSearching: Bool
    let allowsReordering: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let revealInFinder: (URL) -> Void
    let showInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void
    var reauthorize: ((CustomPlaylist.ID, CustomPlaylistEntry.ID) -> Void)? = nil

    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        MediaCollectionBrowser(
            items: projection.entries,
            layout: layout,
            snapshotRevision: AnyHashable(CustomPlaylistSnapshotRevision(
                playlistID: playlist.id,
                contentRevision: contentRevision
            )),
            rowContentRevision: AnyHashable(CustomPlaylistRowContentRevision(
                currentItemID: library.currentItemID,
                playbackState: playbackState,
                allowsReordering: allowsReordering,
                selectionRevision: selection.revision,
                isSearching: isSearching,
                availabilityRevision: playlists.availabilityRevision,
                unavailableItemsRevision: library.unavailableItemsRevision
            )),
            scrollTargetID: projection.search.isEmpty
                ? projection.entryID(for: library.currentItemID) : nil,
            scrollToTopRequest: scrollToTopRequest,
            rowHeight: rowHeight
        ) { entry, layout, artworkSize in
            mediaRow(entry, layout: layout, artworkSize: artworkSize)
        }
    }

    private func mediaRow(
        _ entry: CustomPlaylistEntry,
        layout: MediaBrowserLayout,
        artworkSize: CGSize
    ) -> some View {
        let item = projection.resolvedItemsByEntryID[entry.id]
        return CustomPlaylistMediaRow(
            entry: entry,
            item: item,
            issue: issue(for: entry, item: item),
            isCurrent: item?.id == library.currentItemID,
            isSelecting: selection.isSelecting,
            isSelected: selection.ids.contains(entry.id),
            mediaThumbnailProvider: mediaThumbnailProvider,
            play: {
                guard !isSearching, let item else { return }
                play(item, playlist.id)
                dismiss()
            },
            revealInFinder: {
                guard let item else { return }
                revealInFinder(item.url)
            },
            showInformation: {
                guard let item else { return }
                showInformation(item)
            },
            remove: { try? playlists.removeEntry(entry.id, from: playlist.id) },
            moveUp: { move(entry, by: -1) },
            moveDown: { move(entry, by: 1) },
            canMoveUp: allowsReordering && playlist.entries.first?.id != entry.id,
            canMoveDown: allowsReordering && playlist.entries.last?.id != entry.id,
            toggleSelection: { selection.toggle(entry.id) },
            retry: {
                if let item { play(item, playlist.id) } else { playlists.retryResolution() }
            },
            reauthorize: reauthorize.map { action in
                { action(playlist.id, entry.id) }
            },
            layout: layout,
            artworkSize: artworkSize,
            rowHeight: rowHeight,
            playbackState: item?.id == library.currentItemID ? playbackState : .available
        )
        .disabled(isSearching)
        .customPlaylistDragTarget(
            enabled: allowsReordering,
            entryID: entry.id,
            midpoint: layout == .grid ? artworkSize.width / 2 : rowHeight / 2,
            horizontally: layout == .grid,
            layoutDirection: layoutDirection,
            move: moveEntry
        )
        // Virtualized AppKit cells each host a separate SwiftUI root.
        .environmentObject(localization)
    }

    private func issue(
        for entry: CustomPlaylistEntry,
        item: LibraryMediaItem?
    ) -> CustomPlaylistMediaIssue? {
        if let item, let failure = library.unavailableItemFailures[item.id] {
            return switch failure {
            case .unsupported: .unsupportedFormat
            case .cannotOpen: .cannotOpen
            case .surfaceTimeout: .temporarilyUnavailable
            }
        }
        return playlists.issue(for: entry)
    }

    private func move(_ entry: CustomPlaylistEntry, by offset: Int) {
        guard let current = playlists.collection.playlist(id: playlist.id),
              let index = current.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let destinationIndex = index + offset
        guard current.entries.indices.contains(destinationIndex) else { return }
        let beforeIndex = offset < 0 ? destinationIndex : destinationIndex + 1
        let beforeID = current.entries.indices.contains(beforeIndex)
            ? current.entries[beforeIndex].id : nil
        try? playlists.moveEntry(entry.id, before: beforeID, in: playlist.id)
    }

    private func moveEntry(
        _ draggedID: CustomPlaylistEntry.ID,
        _ destinationID: CustomPlaylistEntry.ID,
        _ placement: CustomPlaylistDropPlacement
    ) -> Bool {
        guard !isSearching, allowsReordering, draggedID != destinationID,
              let current = playlists.collection.playlist(id: playlist.id),
              let destinationIndex = current.entries.firstIndex(where: { $0.id == destinationID }) else {
            return false
        }
        let beforeIndex = placement == .before ? destinationIndex : destinationIndex + 1
        let beforeID = current.entries.indices.contains(beforeIndex)
            ? current.entries[beforeIndex].id : nil
        do {
            try playlists.moveEntry(draggedID, before: beforeID, in: playlist.id)
            return true
        } catch {
            return false
        }
    }

    private var rowHeight: CGFloat {
        MuralumeTheme.Size.playlistRowHeight(for: dynamicTypeSize)
    }
}

private struct CustomPlaylistSnapshotRevision: Hashable {
    let playlistID: CustomPlaylist.ID
    let contentRevision: UInt64
}

private struct CustomPlaylistRowContentRevision: Hashable {
    let currentItemID: LibraryMediaItem.ID?
    let playbackState: LibraryMediaRowPlaybackState
    let allowsReordering: Bool
    let selectionRevision: UInt64
    let isSearching: Bool
    let availabilityRevision: UInt64
    let unavailableItemsRevision: UInt64
}

private enum CustomPlaylistDropPlacement {
    case before
    case after
}

private extension View {
    @ViewBuilder
    func customPlaylistDragTarget(
        enabled: Bool,
        entryID: CustomPlaylistEntry.ID,
        midpoint: CGFloat,
        horizontally: Bool,
        layoutDirection: LayoutDirection,
        move: @escaping (CustomPlaylistEntry.ID, CustomPlaylistEntry.ID, CustomPlaylistDropPlacement) -> Bool
    ) -> some View {
        if enabled {
            draggable(entryID.rawValue.uuidString)
                .dropDestination(for: String.self) { values, location in
                    guard values.count == 1, let value = values.first,
                          let rawID = UUID(uuidString: value) else { return false }
                    let coordinate = horizontally ? location.x : location.y
                    let before = horizontally && layoutDirection == .rightToLeft
                        ? coordinate >= midpoint : coordinate < midpoint
                    return move(
                        CustomPlaylistEntry.ID(rawValue: rawID), entryID,
                        before ? .before : .after
                    )
                }
        } else {
            self
        }
    }
}
