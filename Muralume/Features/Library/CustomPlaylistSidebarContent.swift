import SwiftUI

struct CustomPlaylistSidebarContent: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playlists: CustomPlaylistController
    @ObservedObject var navigation: LibrarySidebarController
    let playback: PlaybackCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playCustomPlaylistItem:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let addVideosToPlaylist: (CustomPlaylist.ID) -> Void
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void
    @Binding var nameEditor: PlaylistNameEditorRequest?
    var reauthorizePlaylistEntry: ((CustomPlaylist.ID, CustomPlaylistEntry.ID) -> Void)? = nil

    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playbackStatus: LibraryPlaybackStatus?
    @State private var pendingDeletion: CustomPlaylist?
    @State private var selection = MediaBrowserSelection<CustomPlaylistEntry.ID>()
    @State private var batchRemovalFailed = false
    @State private var searchScrollToTopRequest: UInt64 = 0
    @StateObject private var detailSearch =
        LatestMediaSearch<CustomPlaylistDetailProjection>(
            hasSameContent: CustomPlaylistDetailProjection.hasSameContent
        )

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
        .alert("playlists.removeSelected.failed", isPresented: $batchRemovalFailed) {
            Button("action.ok", role: .cancel) {}
        }
        .onChange(of: normalizedSearchQuery) {
            selection.clear()
            guard !normalizedSearchQuery.isEmpty else { return }
            searchScrollToTopRequest &+= 1
        }
        .onChange(of: navigation.destination) {
            selection.end()
        }
        .onChange(of: playlists.collectionRevision) {
            retainCurrentSelection()
        }
        .onReceive(LibraryPlaybackStatus.publisher(for: playback)) { playbackStatus = $0 }
        .onDisappear { selection.end() }
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
                        "playlists.count",
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
        let requestID = CustomPlaylistSearchRequestID(
            playlistID: playlist.id,
            playlistRevision: playlists.collectionRevision,
            libraryItemsRevision: playlists.resolutionRevision,
            query: normalizedSearchQuery
        )
        let displayed: (
            key: CustomPlaylistSearchRequestID,
            result: CustomPlaylistDetailProjection,
            contentRevision: UInt64
        )? = detailSearch.latestResult(compatibleWith: requestID) {
            (previous: CustomPlaylistSearchRequestID,
             current: CustomPlaylistSearchRequestID) in
            previous.playlistID == current.playlistID
        }
        let projection = displayed?.result
        let isSearching = detailSearch.result(for: requestID) == nil
        let search = MediaCollectionSearch(query: navigation.query)

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
                        addVideosToPlaylist(playlist.id)
                    }
                    .accessibilityIdentifier(MuralumeAccessibilityIdentifier.playlistAddVideosAction)
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
                    verbatim: (projection?.search.isEmpty ?? true)
                            ? playlistCountText(playlist.entries.count)
                            : localization.localizedFormat(
                                "library.search.results",
                                projection?.entries.count ?? 0,
                                playlist.entries.count
                            )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.searchResultsSummary
                )
                Spacer()
                if !search.isEmpty && !selection.isSelecting {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .help(Text("playlists.reorder.searchHint"))
                        .accessibilityLabel(
                            Text("playlists.reorder.searchHint")
                        )
                }
                persistenceFailureButton
                HStack(spacing: MuralumeTheme.Spacing.libraryBrowserControls) {
                    LibraryBrowserLayoutPicker(layout: $navigation.mediaBrowserLayout)
                    MediaBrowserSelectionControl(
                        isSelecting: selection.isSelecting,
                        isEnabled: !playlist.entries.isEmpty || selection.isSelecting,
                        identifier: MuralumeAccessibilityIdentifier.playlistSelectionButton
                    ) {
                        if selection.isSelecting { selection.end() } else { selection.begin() }
                    }
                }
                .fixedSize()
            }
            .frame(minHeight: MuralumeTheme.Size.playlistStatusBarHeight)

            if selection.isSelecting {
                selectionActions(
                    playlistID: playlist.id,
                    visibleEntries: projection?.entries ?? [],
                    isSearching: isSearching
                )
            }

            Divider().overlay(MuralumeTheme.Colors.border)

            if playlist.entries.isEmpty {
                playlistDetailEmptyState(playlist.id)
            } else if let projection {
                if projection.entries.isEmpty {
                    LibrarySearchEmptyState {
                        navigation.updateQuery("")
                    }
                } else {
                    CustomPlaylistMediaBrowser(
                        library: library,
                        playlists: playlists,
                        selection: $selection,
                        layout: navigation.mediaBrowserLayout,
                        playlist: playlist,
                        projection: projection,
                        contentRevision: displayed?.contentRevision ?? 0,
                        scrollToTopRequest: projection.search.isEmpty ? nil : searchScrollToTopRequest,
                        isSearching: isSearching,
                        allowsReordering: search.isEmpty && !selection.isSelecting && !isSearching,
                        playbackState: playbackStatus?.rowState
                            ?? LibraryPlaybackStatus(playback: playback).rowState,
                        mediaThumbnailProvider: mediaThumbnailProvider,
                        play: playCustomPlaylistItem,
                        revealInFinder: revealMediaInFinder,
                        showInformation: showVideoInformation,
                        dismiss: dismiss,
                        reauthorize: reauthorizePlaylistEntry
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                                .padding(MuralumeTheme.Spacing.small)
                                .accessibilityLabel(Text("library.search.searching"))
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
                ProgressView("library.search.searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: requestID) {
            guard !Task.isCancelled else { return }
            guard !playlist.entries.isEmpty else {
                detailSearch.cancel()
                return
            }
            detailSearch.request(
                key: requestID,
                operation: playlists.detailSearchOperation(
                    for: playlist,
                    query: search.query
                )
            )
        }
        .onChange(of: displayed?.key) {
            guard let projection else { return }
            selection.retain(Set(projection.entries.map(\.id)))
        }
        .onDisappear { detailSearch.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playlistDetail
        )
    }

    private func selectionActions(
        playlistID: CustomPlaylist.ID,
        visibleEntries: [CustomPlaylistEntry],
        isSearching: Bool
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Text(verbatim: localization.localizedFormat("library.selection.count", selection.ids.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityIdentifier(MuralumeAccessibilityIdentifier.playlistSelectedCount)
            Spacer(minLength: 0)
            MediaBrowserSelectionActionsMenu(
                canSelectAll: !isSearching && !visibleEntries.isEmpty,
                canClear: !selection.ids.isEmpty,
                identifier: MuralumeAccessibilityIdentifier.playlistSelectionActionsMenu,
                selectAllIdentifier: MuralumeAccessibilityIdentifier.playlistSelectAllButton,
                clearIdentifier: MuralumeAccessibilityIdentifier.playlistClearSelectionButton,
                selectAll: { selection.selectAll(visibleEntries.map(\.id)) },
                clear: { selection.clear() }
            )
            Button("playlists.removeSelected", role: .destructive) {
                guard !isSearching else { return }
                do {
                    try playlists.removeEntries(selection.ids, from: playlistID)
                    selection.clear()
                } catch {
                    batchRemovalFailed = true
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(isSearching || selection.ids.isEmpty)
            .accessibilityIdentifier(MuralumeAccessibilityIdentifier.playlistRemoveSelectedButton)
        }
        .frame(minHeight: MuralumeTheme.Size.playlistStatusBarHeight)
    }

    private func retainCurrentSelection() {
        guard !selection.ids.isEmpty else { return }
        guard case let .playlist(playlistID) = navigation.destination,
              let playlist = playlists.collection.playlist(id: playlistID) else {
            selection.end()
            return
        }
        selection.retain(Set(playlist.entries.map(\.id)))
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

    private func playlistDetailEmptyState(_ playlistID: CustomPlaylist.ID) -> some View {
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
            Button("playlists.addVideos") {
                addVideosToPlaylist(playlistID)
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

    private func playlistCountText(_ count: Int) -> String {
        localization.localizedFormat(
            "playlists.video.count",
            count
        )
    }

    private var normalizedSearchQuery: String {
        MediaCollectionSearch(query: navigation.query).query
    }
}
