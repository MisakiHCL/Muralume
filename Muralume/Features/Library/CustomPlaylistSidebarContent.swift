import SwiftUI

struct CustomPlaylistSidebarContent: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playlists: CustomPlaylistController
    @ObservedObject var navigation: LibrarySidebarController
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playCustomPlaylistItem:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void
    @Binding var nameEditor: PlaylistNameEditorRequest?

    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingDeletion: CustomPlaylist?
    @State private var searchScrollToTopRequest: UInt64 = 0

    var body: some View {
        Group {
            switch playlists.loadingState {
            case .idle, .loading:
                loadingContent
            case .failed:
                loadingFailureContent
            case .ready:
                switch navigation.destination {
                case .playlists:
                    overview
                case let .playlist(playlistID):
                    if let playlist = playlists.collection.playlist(
                        id: playlistID
                    ) {
                        detail(playlist)
                    } else {
                        Color.clear.onAppear {
                            navigation.playlistDidDelete(playlistID)
                        }
                    }
                case .mediaLibrary, .playQueue:
                    EmptyView()
                }
            }
        }
        .padding(MuralumeTheme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .alert(
            "playlists.delete.title",
            isPresented: deletionIsPresented,
            presenting: pendingDeletion
        ) { playlist in
            Button("playlists.delete", role: .destructive) {
                delete(playlist)
            }
            Button("action.cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { playlist in
            Text(
                verbatim: localization.localizedFormat(
                    "playlists.delete.message",
                    playlist.name
                )
            )
        }
        .onChange(of: normalizedSearchQuery) {
            guard !normalizedSearchQuery.isEmpty else { return }
            searchScrollToTopRequest &+= 1
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            header {
                Button {
                    nameEditor = .create
                } label: {
                    headerIcon("plus")
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size.control
                    )
                )
                .help(Text("playlists.new"))
                .accessibilityLabel(Text("playlists.new"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.newPlaylistButton
                )
            }

            HStack {
                Text(
                    verbatim: localization.localizedFormat(
                        playlists.playlists.count == 1
                            ? "playlists.count.one"
                            : "playlists.count",
                        playlists.playlists.count
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.playlistOverview
                )
                Spacer()
                persistenceFailureButton
            }
            .frame(minHeight: MuralumeTheme.Size.playlistStatusBarHeight)

            Divider().overlay(MuralumeTheme.Colors.border)

            if playlists.playlists.isEmpty {
                playlistEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                        ForEach(playlists.playlists) { playlist in
                            playlistOverviewRow(playlist)
                        }
                    }
                    .padding(
                        .vertical,
                        MuralumeTheme.Size.playlistContentInset
                    )
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func detail(_ playlist: CustomPlaylist) -> some View {
        let projection = playlists.detailProjection(
            for: playlist,
            query: navigation.query,
            using: library.items,
            itemsRevision: library.itemsRevision
        )
        let search = projection.search

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Button {
                    navigation.selectDestination(.playlists)
                } label: {
                    headerIcon("chevron.left")
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size.control
                    )
                )
                .help(Text("playlists.back"))
                .accessibilityLabel(Text("playlists.back"))

                Text(verbatim: playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button("playlists.addVideos") {
                        navigation.selectDestination(.mediaLibrary)
                    }
                    Button("playlists.rename") {
                        nameEditor = .rename(playlist)
                    }
                    Button("playlists.delete", role: .destructive) {
                        pendingDeletion = playlist
                    }
                } label: {
                    headerIcon("ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("playlists.actions"))
                .accessibilityLabel(Text("playlists.actions"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.playlistActionsButton
                )

                closeButton
            }
            .frame(height: MuralumeTheme.Size.control)

            MediaSearchField(
                query: Binding(
                    get: { navigation.query },
                    set: { query in
                        navigation.updateQuery(query)
                    }
                ),
                focusRequest: navigation.searchFocusRequest,
                accessibilityLabel: localization.localizedFormat(
                    "playlists.search.accessibility",
                    playlist.name
                ),
                consumeFocusRequest:
                    navigation.consumeSearchFocusRequest,
                dismissSidebar: dismiss
            )
            .padding(.top, MuralumeTheme.Spacing.small)

            HStack(spacing: MuralumeTheme.Spacing.small) {
                Text(
                    verbatim: search.isEmpty
                        ? playlistCountText(playlist.entries.count)
                        : localization.localizedFormat(
                            "library.search.results",
                            projection.entries.count,
                            playlist.entries.count
                        )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.searchResultsSummary
                )
                Spacer()
                if !search.isEmpty {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .help(Text("playlists.reorder.searchHint"))
                        .accessibilityLabel(
                            Text("playlists.reorder.searchHint")
                        )
                }
                persistenceFailureButton
            }
            .frame(minHeight: MuralumeTheme.Size.playlistStatusBarHeight)

            Divider().overlay(MuralumeTheme.Colors.border)

            if playlist.entries.isEmpty {
                playlistDetailEmptyState
            } else if projection.entries.isEmpty {
                LibrarySearchEmptyState {
                    navigation.updateQuery("")
                }
            } else {
                playlistEntries(
                    projection,
                    in: playlist,
                    allowsReordering: search.isEmpty
                )
            }
        }
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playlistDetail
        )
    }

    private func playlistEntries(
        _ projection: CustomPlaylistDetailProjection,
        in playlist: CustomPlaylist,
        allowsReordering: Bool
    ) -> some View {
        FixedHeightVirtualizedTable(
            items: projection.entries,
            snapshotRevision: CustomPlaylistSnapshotRevision(
                playlistID: playlist.id,
                playlistRevision: playlists.collectionRevision,
                libraryItemsRevision: library.itemsRevision,
                query: projection.search.query
            ),
            rowContentRevision: CustomPlaylistRowContentRevision(
                currentItemID: library.currentItemID,
                allowsReordering: allowsReordering
            ),
            scrollTargetID: projection.search.isEmpty
                ? projection.entryID(for: library.currentItemID)
                : nil,
            scrollToTopRequest: projection.search.isEmpty
                ? nil
                : searchScrollToTopRequest,
            rowHeight: playlistRowHeight,
            rowSpacing: MuralumeTheme.Spacing.small,
            verticalContentInset: MuralumeTheme.Size.playlistContentInset
        ) { entry in
            let item = projection.resolvedItemsByEntryID[entry.id]
            CustomPlaylistMediaRow(
                entry: entry,
                item: item,
                isCurrent: item?.id == library.currentItemID,
                mediaThumbnailProvider: mediaThumbnailProvider,
                play: {
                    guard let item else { return }
                    playCustomPlaylistItem(item, playlist.id)
                    dismiss()
                },
                revealInFinder: {
                    guard let item else { return }
                    revealMediaInFinder(item.url)
                },
                showInformation: {
                    guard let item else { return }
                    showVideoInformation(item)
                },
                remove: { try? playlists.removeEntry(entry.id, from: playlist.id) },
                moveUp: { move(entry, by: -1, in: playlist) },
                moveDown: { move(entry, by: 1, in: playlist) },
                canMoveUp: allowsReordering
                    && playlist.entries.first?.id != entry.id,
                canMoveDown: allowsReordering
                    && playlist.entries.last?.id != entry.id
            )
            .frame(height: playlistRowHeight)
            .customPlaylistDragTarget(
                enabled: allowsReordering,
                entryID: entry.id,
                dropMidpoint: playlistRowHeight / 2
            ) { draggedEntryID, destinationEntryID, placement in
                guard draggedEntryID != destinationEntryID else {
                    return false
                }
                let destinationID: CustomPlaylistEntry.ID?
                switch placement {
                case .before:
                    destinationID = destinationEntryID
                case .after:
                    guard let destinationIndex = playlist.entries.firstIndex(
                        where: { $0.id == destinationEntryID }
                    ) else {
                        return false
                    }
                    let followingIndex = destinationIndex + 1
                    destinationID = playlist.entries.indices.contains(
                        followingIndex
                    ) ? playlist.entries[followingIndex].id : nil
                }
                do {
                    try playlists.moveEntry(
                        draggedEntryID,
                        before: destinationID,
                        in: playlist.id
                    )
                    return true
                } catch {
                    return false
                }
            }
            // NSHostingView is a separate SwiftUI root.
            .environmentObject(localization)
        }
        .scrollIndicators(.visible)
    }

    private func playlistOverviewRow(
        _ playlist: CustomPlaylist
    ) -> some View {
        Button {
            navigation.selectDestination(.playlist(playlist.id))
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.medium) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: MuralumeTheme.Size.iconLarge))
                    .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                    .frame(
                        width: MuralumeTheme.Size.control,
                        height: MuralumeTheme.Size.control
                    )
                    .accessibilityHidden(true)

                VStack(
                    alignment: .leading,
                    spacing: MuralumeTheme.Spacing.xSmall
                ) {
                    Text(verbatim: playlist.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: playlistCountText(playlist.entries.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                }

                Spacer(minLength: MuralumeTheme.Spacing.small)
                Image(systemName: "chevron.right")
                    .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(MuralumeTheme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(MuralumeTheme.Colors.controlFill.opacity(0.52))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("playlists.rename") {
                nameEditor = .rename(playlist)
            }
            Button("playlists.delete", role: .destructive) {
                pendingDeletion = playlist
            }
        }
        .accessibilityLabel(Text(verbatim: playlist.name))
        .accessibilityValue(
            Text(verbatim: playlistCountText(playlist.entries.count))
        )
        .accessibilityHint(Text("playlists.open"))
    }

    private func header<Actions: View>(
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            LibrarySidebarNavigationMenu(
                selection: navigation.destination.navigationItem
            ) { item in
                switch item {
                case .mediaLibrary:
                    navigation.selectDestination(.mediaLibrary)
                case .playlists:
                    navigation.selectDestination(.playlists)
                case .nowPlaying:
                    navigation.selectDestination(.playQueue)
                }
            }
            Spacer(minLength: MuralumeTheme.Spacing.small)
            actions()
            closeButton
        }
        .frame(height: MuralumeTheme.Size.control)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            headerIcon("xmark")
        }
        .buttonStyle(
            MuralumeToolbarButtonStyle(width: MuralumeTheme.Size.control)
        )
        .help(Text("playlists.hide"))
        .accessibilityLabel(Text("playlists.hide"))
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: MuralumeTheme.Size.icon, weight: .semibold))
            .frame(
                width: MuralumeTheme.Size.control,
                height: MuralumeTheme.Size.control
            )
    }

    private var playlistEmptyState: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            Text("playlists.empty")
                .font(.body.weight(.semibold))
            Text("playlists.empty.detail")
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("playlists.new") { nameEditor = .create }
                .buttonStyle(.link)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header {
                EmptyView()
            }
            VStack(spacing: MuralumeTheme.Spacing.medium) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("playlists.loading")
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingFailureContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header {
                EmptyView()
            }
            VStack(spacing: MuralumeTheme.Spacing.medium) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .accessibilityHidden(true)
                Text("playlists.loadFailed")
                    .font(.body.weight(.semibold))
                Button("playlists.retryLoad") {
                    playlists.retryLoading()
                }
                .buttonStyle(.link)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var persistenceFailureButton: some View {
        if playlists.persistenceFailure != nil {
            Button {
                playlists.retryPersistence()
            } label: {
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
            }
            .buttonStyle(.plain)
            .help(Text("playlists.saveFailed"))
            .accessibilityLabel(Text("playlists.saveFailed"))
            .accessibilityHint(Text("playlists.retrySave"))
        }
    }

    private var playlistDetailEmptyState: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            Text("playlists.items.empty")
                .font(.body.weight(.semibold))
            Text("playlists.items.empty.detail")
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("library.playlist") {
                navigation.selectDestination(.mediaLibrary)
            }
            .buttonStyle(.link)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func delete(_ playlist: CustomPlaylist) {
        pendingDeletion = nil
        try? playlists.removePlaylist(id: playlist.id)
        navigation.playlistDidDelete(playlist.id)
    }

    private func move(
        _ entry: CustomPlaylistEntry,
        by offset: Int,
        in playlist: CustomPlaylist
    ) {
        guard let index = playlist.entries.firstIndex(
            where: { $0.id == entry.id }
        ) else {
            return
        }
        let destinationIndex = index + offset
        guard playlist.entries.indices.contains(destinationIndex) else {
            return
        }
        let beforeIndex = offset < 0 ? destinationIndex : destinationIndex + 1
        let destinationID = playlist.entries.indices.contains(beforeIndex)
            ? playlist.entries[beforeIndex].id
            : nil
        try? playlists.moveEntry(
            entry.id,
            before: destinationID,
            in: playlist.id
        )
    }

    private func playlistCountText(_ count: Int) -> String {
        localization.localizedFormat(
            count == 1 ? "playlists.video.count.one" : "playlists.video.count",
            count
        )
    }

    private var playlistRowHeight: CGFloat {
        MuralumeTheme.Size.playlistRowHeight(for: dynamicTypeSize)
    }

    private var normalizedSearchQuery: String {
        MediaCollectionSearch(query: navigation.query).query
    }
}

private struct CustomPlaylistSnapshotRevision: Hashable {
    let playlistID: CustomPlaylist.ID
    let playlistRevision: UInt64
    let libraryItemsRevision: UInt64
    let query: String
}

private struct CustomPlaylistRowContentRevision: Hashable {
    let currentItemID: LibraryMediaItem.ID?
    let allowsReordering: Bool
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
        dropMidpoint: CGFloat,
        moveBefore: @escaping (
            CustomPlaylistEntry.ID,
            CustomPlaylistEntry.ID,
            CustomPlaylistDropPlacement
        ) -> Bool
    ) -> some View {
        if enabled {
            draggable(entryID.rawValue.uuidString)
                .dropDestination(for: String.self) { values, location in
                    guard let value = values.first,
                          let rawID = UUID(uuidString: value) else {
                        return false
                    }
                    return moveBefore(
                        CustomPlaylistEntry.ID(rawValue: rawID),
                        entryID,
                        location.y < dropMidpoint
                            ? .before
                            : .after
                    )
                }
        } else {
            self
        }
    }

    @ViewBuilder
    func customPlaylistMoveAccessibilityActions(
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void
    ) -> some View {
        if canMoveUp && canMoveDown {
            accessibilityAction(
                named: Text("playlists.moveUp"),
                moveUp
            )
            .accessibilityAction(
                named: Text("playlists.moveDown"),
                moveDown
            )
        } else if canMoveUp {
            accessibilityAction(
                named: Text("playlists.moveUp"),
                moveUp
            )
        } else if canMoveDown {
            accessibilityAction(
                named: Text("playlists.moveDown"),
                moveDown
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func customPlaylistAvailabilityAccessibility(
        isAvailable: Bool
    ) -> some View {
        if isAvailable {
            self
        } else {
            accessibilityValue(Text("library.item.unavailable"))
                .accessibilityHint(Text("library.item.unavailable"))
        }
    }
}

private struct CustomPlaylistMediaRow: View {
    let entry: CustomPlaylistEntry
    let item: LibraryMediaItem?
    let isCurrent: Bool
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void
    let revealInFinder: () -> Void
    let showInformation: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        rowControl
        .contextMenu {
            if item != nil {
                Button("videoInfo.menu", action: showInformation)
                Button("library.item.revealInFinder", action: revealInFinder)
            }
            if canMoveUp {
                Button("playlists.moveUp", action: moveUp)
            }
            if canMoveDown {
                Button("playlists.moveDown", action: moveDown)
            }
            Divider()
            Button("playlists.removeVideo", role: .destructive, action: remove)
        }
        .accessibilityLabel(
            Text(verbatim: item?.displayName ?? entry.media.lastKnownDisplayName)
        )
        .customPlaylistAvailabilityAccessibility(isAvailable: item != nil)
        .customPlaylistMoveAccessibilityActions(
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: moveUp,
            moveDown: moveDown
        )
    }

    @ViewBuilder
    private var rowControl: some View {
        if item == nil {
            rowLabel
        } else {
            Button(action: play) {
                rowLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var rowLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            if let item {
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )
            } else {
                unavailableThumbnail
            }

            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.xSmall
            ) {
                Text(
                    verbatim: item?.displayName
                        ?? entry.media.lastKnownDisplayName
                )
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                Text(
                    verbatim: item?.relativePath
                        ?? entry.media.mediaItemID.relativePath
                )
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: MuralumeTheme.Spacing.small)
            if item == nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .accessibilityHidden(true)
            } else if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                    .accessibilityHidden(true)
            }
        }
        .padding(MuralumeTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: MuralumeTheme.Size.control * 2)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(
                isCurrent
                    ? MuralumeTheme.Colors.controlHover
                    : MuralumeTheme.Colors.controlFill.opacity(0.36)
            )
        }
    }

    private var unavailableThumbnail: some View {
        ZStack {
            MuralumeTheme.Colors.panelRaised
            Image(systemName: "film")
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
        }
        .frame(
            width: MuralumeTheme.Size.playlistArtworkWidth,
            height: MuralumeTheme.Size.playlistArtworkHeight
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
    }
}
