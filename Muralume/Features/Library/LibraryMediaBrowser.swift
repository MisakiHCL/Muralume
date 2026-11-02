import SwiftUI

/// Browsing and selection are projections of the library, never playback collections.
struct LibraryMediaBrowser: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @Binding var layout: MediaBrowserLayout
    @Binding var selection: MediaBrowserSelection<MediaBrowserItemIdentity>
    let items: [LibraryMediaItem]
    let snapshotRevision: LibraryPlaylistSnapshotRevision
    let contentSnapshotRevision: AnyHashable
    let scrollToTopRequest: UInt64?
    let isSearching: Bool
    let clearSearch: () -> Void
    let playbackState: LibraryMediaRowPlaybackState
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let customPlaylists: [CustomPlaylist]
    let customPlaylistsRevision: UInt64
    let play: (LibraryMediaItem) -> Void
    let addToPlaylist: (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let addItemsToPlaylist: ([LibraryMediaItem], CustomPlaylist.ID) throws -> Void
    let createPlaylistWithItems: ([LibraryMediaItem], @escaping () -> Void) -> Void
    let revealInFinder: (URL) -> Void
    let showInformation: (LibraryMediaItem) -> Void
    let reauthorizeSource: (UnavailableMediaSource) -> Void

    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAddFailure = false

    var body: some View {
        VStack(spacing: 0) {
            if selection.isSelecting {
                selectionControls
            }
            browser
                .disabled(isSearching)
                .overlay(alignment: .topTrailing) {
                    if isSearching && !items.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(MuralumeTheme.Spacing.small)
                            .accessibilityLabel(Text("library.search.searching"))
                            .allowsHitTesting(false)
                    }
                }
        }
        .onChange(of: snapshotRevision.query) { selection.clear() }
        .onChange(of: snapshotRevision) {
            guard !isSearching, !selection.ids.isEmpty else { return }
            selection.retain(Set(items.map(MediaBrowserItemIdentity.init)))
        }
        .onChange(of: library.itemsRevision) {
            guard !selection.ids.isEmpty else { return }
            selection.retain(Set(library.items.map(MediaBrowserItemIdentity.init)))
        }
        .alert("playlists.addSelected.failed", isPresented: $showsAddFailure) {
            Button("action.ok", role: .cancel) {}
        }
    }

    private var selectionControls: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Text(verbatim: localization.localizedFormat("library.selection.count", selection.ids.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityIdentifier(MuralumeAccessibilityIdentifier.librarySelectedCount)
            Spacer(minLength: 0)
            MediaBrowserSelectionActionsMenu(
                canSelectAll: !isSearching && !items.isEmpty,
                canClear: !selection.ids.isEmpty,
                identifier: MuralumeAccessibilityIdentifier.librarySelectionActionsMenu,
                selectAllIdentifier: MuralumeAccessibilityIdentifier.librarySelectAllButton,
                clearIdentifier: MuralumeAccessibilityIdentifier.libraryClearSelectionButton,
                selectAll: {
                    selection.selectAll(items.compactMap {
                        guard let current = library.libraryItemsByID[$0.id],
                              MediaBrowserItemIdentity(current) == MediaBrowserItemIdentity($0) else {
                            return nil
                        }
                        return MediaBrowserItemIdentity(current)
                    })
                },
                clear: { selection.clear() }
            )

            Menu {
                ForEach(customPlaylists) { playlist in
                    Button {
                        addSelection(to: playlist.id)
                    } label: {
                        Text(verbatim: playlist.name)
                    }
                    .disabled(isSearching || selection.ids.isEmpty)
                }
                if !customPlaylists.isEmpty { Divider() }
                Button("playlists.new") {
                    createPlaylist(using: selectedItems)
                }
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.playlistCreateFromSelectionButton
                )
            } label: {
                Label("playlists.addTo", systemImage: "text.badge.plus")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(Text("playlists.addTo"))
            .accessibilityIdentifier(MuralumeAccessibilityIdentifier.libraryAddSelectedMenu)
        }
        .frame(minHeight: MuralumeTheme.Size.playlistStatusBarHeight)
    }

    @ViewBuilder
    private var browser: some View {
        if items.isEmpty {
            if isSearching {
                ProgressView("library.search.searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibrarySearchEmptyState(clear: clearSearch)
            }
        } else {
            MediaCollectionBrowser(
                items: items,
                layout: layout,
                snapshotRevision: contentSnapshotRevision,
                rowContentRevision: AnyHashable(rowContentRevision),
                scrollTargetID: scrollTargetID,
                scrollToTopRequest: scrollToTopRequest,
                rowHeight: MuralumeTheme.Size.playlistRowHeight(for: dynamicTypeSize)
            ) { item, layout, size in
                mediaRow(item, layout: layout, itemSize: size)
            }
        }
    }

    private func mediaRow(
        _ item: LibraryMediaItem,
        layout: MediaBrowserLayout,
        itemSize: CGSize
    ) -> some View {
        LibraryMediaRow(
            item: item,
            isCurrent: library.currentItemID == item.id,
            playbackState: library.unavailableItemIDs.contains(item.id)
                ? .unavailable : library.currentItemID == item.id ? playbackState : .available,
            rowHeight: MuralumeTheme.Size.playlistRowHeight(for: dynamicTypeSize),
            mediaThumbnailProvider: mediaThumbnailProvider,
            play: {
                guard !isSearching,
                      let currentItem = library.libraryItemsByID[item.id],
                      MediaBrowserItemIdentity(currentItem) == MediaBrowserItemIdentity(item) else { return }
                if selection.isSelecting {
                    selection.toggle(MediaBrowserItemIdentity(currentItem))
                } else {
                    play(currentItem)
                }
            },
            revealInFinder: { revealInFinder(item.url) },
            showInformation: { showInformation(item) },
            reauthorizeSource: reauthorizeAction(for: item),
            customPlaylists: customPlaylists,
            addToPlaylist: { addToPlaylist(item, $0) },
            createPlaylist: {
                createPlaylist(using: [item])
            },
            layout: layout,
            artworkSize: itemSize,
            isSelecting: selection.isSelecting,
            isSelected: selection.ids.contains(MediaBrowserItemIdentity(item))
        )
        // Each AppKit hosting view has its own SwiftUI root.
        .disabled(isSearching)
        .environmentObject(localization)
    }

    private var scrollTargetID: LibraryMediaItem.ID? {
        snapshotRevision.query.isEmpty ? library.currentItemID : nil
    }

    private var rowContentRevision: MediaBrowserRowContentRevision {
        MediaBrowserRowContentRevision(
            library: LibraryPlaylistRowContentRevision(
                currentItemID: library.currentItemID,
                unavailableItemsRevision: library.unavailableItemsRevision,
                playbackState: playbackState,
                playlistCollectionRevision: customPlaylistsRevision,
                playlistMenuEntries: customPlaylists.map {
                    LibraryPlaylistMenuEntryRevision(id: $0.id, name: $0.name)
                }
            ),
            selectionRevision: selection.revision,
            isSearching: isSearching
        )
    }

    private func reauthorizeAction(for item: LibraryMediaItem) -> (() -> Void)? {
        guard library.unavailableItemIDs.contains(item.id),
              let source = library.unavailableSource(for: item) else { return nil }
        return { reauthorizeSource(source) }
    }

    private var selectedItems: [LibraryMediaItem] {
        guard !isSearching else { return [] }
        // Preserve the displayed sort order rather than the Set's enumeration order.
        return items.compactMap { item in
            guard let current = library.libraryItemsByID[item.id],
                  selection.ids.contains(MediaBrowserItemIdentity(current)),
                  MediaBrowserItemIdentity(current) == MediaBrowserItemIdentity(item) else { return nil }
            return current
        }
    }

    private func createPlaylist(using items: [LibraryMediaItem]) {
        let selectionBinding = $selection
        createPlaylistWithItems(items) {
            selectionBinding.wrappedValue.clear()
        }
    }

    private func addSelection(to playlistID: CustomPlaylist.ID) {
        guard !isSearching else { return }
        let selectedItems = self.selectedItems
        guard !selectedItems.isEmpty else { return }
        do {
            try addItemsToPlaylist(selectedItems, playlistID)
            selection.clear()
        } catch {
            showsAddFailure = true
        }
    }

}

private struct MediaBrowserRowContentRevision: Hashable {
    let library: LibraryPlaylistRowContentRevision
    let selectionRevision: UInt64
    let isSearching: Bool
}
