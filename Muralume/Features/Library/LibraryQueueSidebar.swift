import Combine
import SwiftUI

struct LibraryQueueSidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var pendingRootRemoval: MediaLibraryRoot?
    @State private var pendingUnavailableSourceRemoval:
        UnavailableMediaSource?
    @State private var playbackStatus: LibraryPlaybackStatus
    @State private var searchScrollToTopRequest: UInt64 = 0
    @State private var mediaSelection = MediaBrowserSelection<MediaBrowserItemIdentity>()
    @StateObject private var searchProjectionCache =
        LatestMediaSearch<MediaLibrarySearchProjection>(
            hasSameContent: MediaLibrarySearchProjection.hasSameContent
        )
    @Binding private var sidebarSection: LibrarySidebarSection
    @Binding private var searchQuery: String
    @Binding private var browserLayout: MediaBrowserLayout
    let playbackQueueFocusRequest: UInt64
    let searchFocusRequest: UInt64
    let consumeSearchFocusRequest: (UInt64) -> Void
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isEditing: Bool
    let setEditing: (Bool) -> Void
    let addMedia: () -> Void
    let retryUnavailableSourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void
    let reauthorizeMediaSource: (UnavailableMediaSource) -> Void
    let removeUnavailableMediaSource: (UnavailableMediaSource) -> Void
    let canRestoreDynamicDesktop: Bool
    let addTemporaryItemsToLibrary: () -> Void
    let restoreDynamicDesktop: () -> Void
    let playLibraryItem: (LibraryMediaItem) -> Void
    let customPlaylists: [CustomPlaylist]
    let customPlaylistsRevision: UInt64
    let showPlaylists: () -> Void
    let addLibraryItemToPlaylist:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let addLibraryItemsToPlaylist:
        ([LibraryMediaItem], CustomPlaylist.ID) throws -> Void
    let createPlaylistWithItems:
        ([LibraryMediaItem], @escaping () -> Void) -> Void
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void

    init(
        library: MediaLibraryCoordinator,
        playback: PlaybackCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        sidebarSection: Binding<LibrarySidebarSection>,
        searchQuery: Binding<String>,
        browserLayout: Binding<MediaBrowserLayout>,
        playbackQueueFocusRequest: UInt64,
        searchFocusRequest: UInt64,
        consumeSearchFocusRequest: @escaping (UInt64) -> Void,
        isEditing: Bool,
        setEditing: @escaping (Bool) -> Void,
        addMedia: @escaping () -> Void,
        retryUnavailableSourceAccess: @escaping () -> Void,
        reauthorizeMediaSources: @escaping () -> Void,
        reauthorizeMediaSource: @escaping (UnavailableMediaSource) -> Void,
        removeUnavailableMediaSource: @escaping (
            UnavailableMediaSource
        ) -> Void,
        canRestoreDynamicDesktop: Bool,
        addTemporaryItemsToLibrary: @escaping () -> Void,
        restoreDynamicDesktop: @escaping () -> Void,
        playLibraryItem: @escaping (LibraryMediaItem) -> Void,
        customPlaylists: [CustomPlaylist],
        customPlaylistsRevision: UInt64,
        showPlaylists: @escaping () -> Void,
        addLibraryItemToPlaylist: @escaping (
            LibraryMediaItem,
            CustomPlaylist.ID
        ) -> Void,
        addLibraryItemsToPlaylist: @escaping (
            [LibraryMediaItem], CustomPlaylist.ID
        ) throws -> Void,
        createPlaylistWithItems: @escaping (
            [LibraryMediaItem], @escaping () -> Void
        ) -> Void,
        revealMediaInFinder: @escaping (URL) -> Void,
        showVideoInformation: @escaping (LibraryMediaItem) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.library = library
        self.playback = playback
        self.mediaThumbnailProvider = mediaThumbnailProvider
        _sidebarSection = sidebarSection
        _searchQuery = searchQuery
        _browserLayout = browserLayout
        self.playbackQueueFocusRequest = playbackQueueFocusRequest
        self.searchFocusRequest = searchFocusRequest
        self.consumeSearchFocusRequest = consumeSearchFocusRequest
        self.isEditing = isEditing
        self.setEditing = setEditing
        self.addMedia = addMedia
        self.retryUnavailableSourceAccess = retryUnavailableSourceAccess
        self.reauthorizeMediaSources = reauthorizeMediaSources
        self.reauthorizeMediaSource = reauthorizeMediaSource
        self.removeUnavailableMediaSource = removeUnavailableMediaSource
        self.canRestoreDynamicDesktop = canRestoreDynamicDesktop
        self.addTemporaryItemsToLibrary = addTemporaryItemsToLibrary
        self.restoreDynamicDesktop = restoreDynamicDesktop
        self.playLibraryItem = playLibraryItem
        self.customPlaylists = customPlaylists
        self.customPlaylistsRevision = customPlaylistsRevision
        self.showPlaylists = showPlaylists
        self.addLibraryItemToPlaylist = addLibraryItemToPlaylist
        self.addLibraryItemsToPlaylist = addLibraryItemsToPlaylist
        self.createPlaylistWithItems = createPlaylistWithItems
        self.revealMediaInFinder = revealMediaInFinder
        self.showVideoInformation = showVideoInformation
        self.dismiss = dismiss
        _playbackStatus = State(
            initialValue: LibraryPlaybackStatus(playback: playback)
        )
    }

    var body: some View {
        let requestID = searchRequestID
        let requestedItems = library.items
        let requestedSearch = MediaCollectionSearch(query: searchQuery)
        return VStack(alignment: .leading, spacing: 0) {
            header

            if !isEditing, sidebarSection == .mediaLibrary {
                MediaSearchField(
                    query: $searchQuery,
                    focusRequest: searchFocusRequest,
                    accessibilityLabel: localization.localized(
                        "library.search.accessibility"
                    ),
                    consumeFocusRequest: consumeSearchFocusRequest,
                    dismissSidebar: dismiss
                )
                .padding(.top, MuralumeTheme.Spacing.small)
            }

            sidebarStatusBar
                .frame(
                    minHeight: MuralumeTheme.Size.playlistStatusBarHeight
                )

            Divider()
                .overlay(MuralumeTheme.Colors.border)

            if isEditing {
                rootEditor
            } else {
                playlistContent
            }
        }
        .padding(MuralumeTheme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySidebar
        )
        .alert(
            LocalizedStringKey(rootRemovalTitleKey),
            isPresented: rootRemovalAlertIsPresented,
            presenting: pendingRootRemoval
        ) { root in
            Button(
                LocalizedStringKey(rootRemovalConfirmKey(for: root)),
                role: .destructive
            ) {
                let removesLastRoot = library.sourceRoots.count == 1
                    && library.unavailableSources.isEmpty
                pendingRootRemoval = nil
                if removesLastRoot {
                    setEditing(false)
                }
                Task {
                    await library.removeRoot(root)
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingRootRemoval = nil
            }
        } message: { root in
            Text(
                verbatim: localization.localizedFormat(
                    rootRemovalMessageKey(for: root),
                    root.displayName
                )
            )
        }
        .alert(
            "library.source.unavailable.remove.title",
            isPresented: unavailableSourceRemovalAlertIsPresented,
            presenting: pendingUnavailableSourceRemoval
        ) { source in
            Button(
                "library.source.unavailable.remove.confirm",
                role: .destructive
            ) {
                pendingUnavailableSourceRemoval = nil
                removeUnavailableMediaSource(source)
                if library.sourceRoots.isEmpty,
                   library.unavailableSources.isEmpty {
                    setEditing(false)
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingUnavailableSourceRemoval = nil
            }
        } message: { source in
            Text(
                verbatim: localization.localizedFormat(
                    "library.source.unavailable.remove.message",
                    source.displayName
                )
            )
        }
        .alert("playlists.access.preserveFailed", isPresented: $library.sourceRemovalPreservationFailed) {
            Button("action.ok", role: .cancel) {}
        } message: {
            Text("playlists.access.preserveFailed.message")
        }
        .onReceive(playbackStatusPublisher) { status in
            playbackStatus = status
        }
        .task(id: requestID) {
            guard !Task.isCancelled else { return }
            guard !requestedSearch.isEmpty else {
                searchProjectionCache.cancel()
                return
            }
            searchProjectionCache.request(key: requestID) {
                MediaLibrarySearchProjection(
                    search: requestedSearch,
                    items: try requestedSearch.filteredItemsCancellable(from: requestedItems)
                )
            }
        }
        .onDisappear {
            searchProjectionCache.cancel()
            mediaSelection.end()
        }
        .onChange(of: sidebarSection) { mediaSelection.end() }
        .onChange(of: isEditing) { mediaSelection.end() }
        .onChange(of: library.itemsRevision) {
            if library.items.isEmpty { mediaSelection.end() }
        }
        .onChange(of: normalizedSearchQuery) {
            if normalizedSearchQuery.isEmpty {
                // Clearing search restores the existing current-item
                // centering behavior instead of pinning the full library to
                // its first row.
                return
            } else {
                searchScrollToTopRequest &+= 1
            }
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            sidebarTitle

            Spacer(minLength: MuralumeTheme.Spacing.small)

            if sidebarSection == .mediaLibrary {
                if isEditing {
                    Button {
                        library.refresh()
                    } label: {
                        headerActionIcon(systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(
                        MuralumeToolbarButtonStyle(
                            width: MuralumeTheme.Size.control
                        )
                    )
                    .disabled(!library.canRefresh)
                    .help(Text("library.refresh"))
                    .accessibilityLabel(Text("library.refresh"))
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier.refreshLibraryButton
                    )
                } else {
                    Button(action: addMedia) {
                        headerActionIcon(systemImage: "plus")
                    }
                    .buttonStyle(
                        MuralumeToolbarButtonStyle(
                            width: MuralumeTheme.Size.control
                        )
                    )
                    .help(Text("library.add.media"))
                    .accessibilityLabel(Text("library.add.media"))
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier.addMediaButton
                    )
                }
            }

            if sidebarSection == .mediaLibrary,
               !library.sourceRoots.isEmpty || !library.unavailableSources.isEmpty {
                Button {
                    setEditing(!isEditing)
                } label: {
                    headerActionIcon(
                        systemImage: isEditing ? "checkmark"
                            : sourceNeedsAttention ? "exclamationmark.triangle" : "pencil"
                    )
                    .foregroundStyle(
                        !isEditing && sourceNeedsAttention
                            ? MuralumeTheme.Colors.warning : MuralumeTheme.Colors.textPrimary
                    )
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        kind: isEditing ? .selected : .standard,
                        width: MuralumeTheme.Size.control
                    )
                )
                .help(
                    Text(
                        LocalizedStringKey(
                            isEditing ? "library.done"
                                : sourceNeedsAttention ? "library.source.health.needsAttention" : "library.edit"
                        )
                    )
                )
                .accessibilityLabel(
                    Text(
                        LocalizedStringKey(
                            isEditing ? "library.done" : "library.edit"
                        )
                    )
                )
                .accessibilityValue(Text(verbatim:
                    !isEditing && sourceNeedsAttention
                        ? localization.localized("library.source.health.needsAttention") : ""
                ))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.editLibraryButton
                )
            }

            if sidebarSection == .playQueue, hasQueueActions {
                queueActionsMenu
            }

            Button(action: dismiss) {
                headerActionIcon(systemImage: "xmark")
            }
            .buttonStyle(
                MuralumeToolbarButtonStyle(
                    width: MuralumeTheme.Size.control
                )
            )
            .help(Text(LocalizedStringKey(sidebarHideLabelKey)))
            .accessibilityLabel(
                Text(LocalizedStringKey(sidebarHideLabelKey))
            )
        }
        .frame(
            height: MuralumeTheme.Size.control,
            alignment: .center
        )
    }

    @ViewBuilder
    private var sidebarTitle: some View {
        if isEditing {
            HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                Image(systemName: navigationItem.systemImage)
                    .font(
                        .system(
                            size: MuralumeTheme.Size.icon,
                            weight: .semibold
                        )
                    )
                    .symbolRenderingMode(.monochrome)
                    .frame(
                        width: MuralumeTheme.Size.sidebarTitleIconWidth,
                        height: MuralumeTheme.Size.iconLarge,
                        alignment: .center
                    )
                    .accessibilityHidden(true)

                Text(navigationItem.localizedKey)
                    .font(.headline)
                    .lineLimit(1)
            }
            .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .padding(.horizontal, MuralumeTheme.Spacing.small)
                .padding(.vertical, MuralumeTheme.Spacing.small)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.libraryTitle
                )
        } else {
            LibrarySidebarNavigationMenu(selection: navigationItem) { item in
                switch item {
                case .mediaLibrary:
                    sidebarSection = .mediaLibrary
                case .playlists:
                    showPlaylists()
                case .nowPlaying:
                    sidebarSection = .playQueue
                }
            }
        }
    }

    private var navigationItem: LibrarySidebarNavigationItem {
        sidebarSection == .mediaLibrary ? .mediaLibrary : .nowPlaying
    }

    private var sidebarHideLabelKey: String {
        sidebarSection == .mediaLibrary
            ? "library.playlist.hide"
            : "queue.hide"
    }

    private var hasQueueActions: Bool {
        library.isTemporaryPlayback || canRestoreDynamicDesktop
    }

    private var queueActionsMenu: some View {
        Menu {
            if library.isTemporaryPlayback {
                Button(action: addTemporaryItemsToLibrary) {
                    Label("queue.addToLibrary", systemImage: "plus")
                }
            }

            if canRestoreDynamicDesktop {
                Button(action: restoreDynamicDesktop) {
                    Label(
                        "external.open.restoreDynamicDesktop",
                        systemImage: "display"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .frame(
                    width: MuralumeTheme.Size.control,
                    height: MuralumeTheme.Size.control
                )
                .background {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .fill(MuralumeTheme.Colors.controlFill)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: MuralumeTheme.Radius.medium,
                            style: .continuous
                        )
                        .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
                    }
                }
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("queue.actions"))
        .accessibilityLabel(Text("queue.actions"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playbackQueueActionsButton
        )
    }

    private func headerActionIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(
                .system(
                    size: MuralumeTheme.Size.icon,
                    weight: .semibold
                )
            )
    }

    private var libraryStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            librarySummary(showsInlineRetry: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: MuralumeTheme.Spacing.libraryBrowserControls) {
                LibraryBrowserLayoutPicker(layout: $browserLayout)
                mediaSelectionButton
                sortMenu
            }
            .fixedSize()
        }
    }

    private var mediaSelectionButton: some View {
        let title = LocalizedStringKey(mediaSelection.isSelecting
            ? "library.selection.done" : "library.selection.begin")
        return Button {
            if mediaSelection.isSelecting { mediaSelection.end() } else { mediaSelection.begin() }
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .buttonStyle(LibraryBrowserControlStyle(isSelected: mediaSelection.isSelecting))
        .disabled(library.items.isEmpty)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(mediaSelection.isSelecting ? .isSelected : [])
        .accessibilityIdentifier(MuralumeAccessibilityIdentifier.librarySelectionButton)
    }

    @ViewBuilder
    private var sidebarStatusBar: some View {
        if isEditing {
            editorStatusBar
        } else if sidebarSection == .playQueue {
            queueStatusBar
        } else {
            libraryStatusBar
        }
    }

    private var queueStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            if let position = library.currentPosition,
               library.queueCount > 0 {
                Text(
                    verbatim: localization.localizedFormat(
                        "queue.position",
                        position,
                        library.queueCount
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .accessibilityLabel(
                    Text(
                        verbatim: localization.localizedFormat(
                            "queue.position.accessibility",
                            position,
                            library.queueCount
                        )
                    )
                )
            } else {
                Text("queue.empty")
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }

            Spacer(minLength: MuralumeTheme.Spacing.small)

            if library.upNextItemCount > 0 {
                Text(
                    verbatim: localization.localizedFormat(
                        "queue.upNext.count",
                        library.upNextItemCount
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
            }
        }
    }

    private var editorStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            libraryCountSummary
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rootEditor: some View {
        LibraryRootEditor(
            roots: library.sourceRoots,
            unavailableSources: library.unavailableSources,
            healthForRoot: library.sourceHealth(for:),
            healthForUnavailableSource: library.sourceHealth(for:),
            canRetryRoots: library.canRefresh,
            canRetryUnavailableSources: library.canRetrySourceAccess,
            requestRetry: { _ in library.refresh() },
            requestUnavailableRetry: { _ in retryUnavailableSourceAccess() },
            requestRemoval: { root in
                pendingRootRemoval = root
            },
            requestRootReauthorization: { root in
                guard let source = library.reauthorizationSource(for: root) else { return }
                reauthorizeMediaSource(source)
            },
            requestReauthorization: reauthorizeMediaSource,
            requestUnavailableRemoval: { source in
                pendingUnavailableSourceRemoval = source
            }
        )
    }

    private var rootRemovalAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                pendingRootRemoval != nil
            },
            set: { isPresented in
                if !isPresented {
                    pendingRootRemoval = nil
                }
            }
        )
    }

    private var unavailableSourceRemovalAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                pendingUnavailableSourceRemoval != nil
            },
            set: { isPresented in
                if !isPresented {
                    pendingUnavailableSourceRemoval = nil
                }
            }
        )
    }

    @ViewBuilder
    private func librarySummary(showsInlineRetry: Bool) -> some View {
        switch library.scanState {
        case .idle:
            if library.sourceAccessState == .temporarilyUnavailable {
                Text("library.sourceAccess.unavailable.short")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            } else {
                libraryCountSummary
            }
        case .scanning:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .accessibilityHidden(true)
                Text("library.scanning")
                    .font(.caption)
                    .lineLimit(1)
            }
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .ready:
            libraryCountSummary
        case let .failed(failure):
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(failure.localizedTitleKey))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                if showsInlineRetry {
                    Button("library.retry") {
                        library.refresh()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var libraryCountSummary: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Text(videoCountText)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .truncationMode(.tail)

            Text(sourceCountText)
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .truncationMode(.tail)

        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: librarySummaryAccessibilityLabel)
        )
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySummary
        )
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MediaLibrarySortField.allCases, id: \.self) { field in
                Button {
                    library.setSortField(field)
                } label: {
                    if library.sort.field == field {
                        Label(
                            LocalizedStringKey(field.localizedKey),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(LocalizedStringKey(field.localizedKey))
                    }
                }
            }

            Divider()

            ForEach(
                MediaLibrarySortDirection.allCases,
                id: \.self
            ) { direction in
                Button {
                    library.setSortDirection(direction)
                } label: {
                    if library.sort.direction == direction {
                        Label(
                            LocalizedStringKey(direction.localizedKey),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(
                            LocalizedStringKey(direction.localizedKey)
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(LibraryBrowserControlStyle())
        .fixedSize()
        .help(Text("library.sort"))
        .accessibilityLabel(Text("library.sort"))
        .accessibilityValue(Text(verbatim: sortAccessibilityValue))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySortButton
        )
    }

    @ViewBuilder
    private var playlistContent: some View {
        if sidebarSection == .playQueue {
            PlaybackQueueSidebarContent(
                library: library,
                mediaThumbnailProvider: mediaThumbnailProvider,
                playbackState: playbackStatus.rowState,
                focusRequest: playbackQueueFocusRequest,
                revealMediaInFinder: revealMediaInFinder,
                showVideoInformation: showVideoInformation,
                addCurrentTemporaryToLibrary: {
                    if library.supportsAsynchronousImportPreparation {
                        Task {
                            _ = await library.addCurrentTemporaryItemToLibraryAsync()
                        }
                    } else {
                        _ = library.addCurrentTemporaryItemToLibrary()
                    }
                },
                play: { item in
                    library.play(item)
                    dismiss()
                }
            )
        } else if library.items.isEmpty {
            LibrarySidebarEmptyState(
                scanState: library.scanState,
                sourceAccessState: library.sourceAccessState,
                canRetrySourceAccess: library.canRetrySourceAccess,
                retryScan: { library.refresh() },
                retrySourceAccess: retryUnavailableSourceAccess,
                reauthorizeMediaSources: reauthorizeMediaSources
            )
        } else {
            LibraryMediaBrowser(
                library: library,
                layout: $browserLayout,
                selection: $mediaSelection,
                items: filteredLibraryItems,
                snapshotRevision: LibraryPlaylistSnapshotRevision(
                    itemsRevision: normalizedSearchQuery.isEmpty
                        ? library.itemsRevision
                        : displayedSearchResult?.key.itemsRevision ?? library.itemsRevision,
                    query: normalizedSearchQuery
                ),
                contentSnapshotRevision: displayedContentSnapshotRevision,
                scrollToTopRequest: normalizedSearchQuery.isEmpty
                    ? nil : searchScrollToTopRequest,
                isSearching: isSearching,
                clearSearch: { searchQuery = "" },
                playbackState: playbackStatus.rowState,
                mediaThumbnailProvider: mediaThumbnailProvider,
                customPlaylists: customPlaylists,
                customPlaylistsRevision: customPlaylistsRevision,
                play: { item in
                    playLibraryItem(item)
                    dismiss()
                },
                addToPlaylist: addLibraryItemToPlaylist,
                addItemsToPlaylist: addLibraryItemsToPlaylist,
                createPlaylistWithItems: createPlaylistWithItems,
                revealInFinder: revealMediaInFinder,
                showInformation: showVideoInformation,
                reauthorizeSource: reauthorizeMediaSource
            )
        }
    }

    private var playbackStatusPublisher:
        AnyPublisher<LibraryPlaybackStatus, Never> {
        Publishers.CombineLatest3(
            playback.$readiness,
            playback.$isPlaybackRequested,
            playback.$hasPlayableMedia
        )
        .map { readiness, isPlaybackRequested, hasPlayableMedia in
            LibraryPlaybackStatus(
                readiness: readiness,
                isPlaybackRequested: isPlaybackRequested,
                hasPlayableMedia: hasPlayableMedia
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private var videoCountText: String {
        if !normalizedSearchQuery.isEmpty, let displayed = displayedSearchResult {
            return localization.localizedFormat(
                "library.search.results",
                displayed.result.items.count,
                library.items.count
            )
        }
        return localization.localizedFormat(
            "library.video.count",
            library.items.count
        )
    }

    private var normalizedSearchQuery: String {
        MediaCollectionSearch(query: searchQuery).query
    }

    private var searchRequestID: MediaLibrarySearchRequestID {
        MediaLibrarySearchRequestID(
            itemsRevision: library.itemsRevision,
            query: normalizedSearchQuery
        )
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
            && searchProjectionCache.result(for: searchRequestID) == nil
    }

    private var displayedSearchResult: (
        key: MediaLibrarySearchRequestID,
        result: MediaLibrarySearchProjection,
        contentRevision: UInt64
    )? {
        searchProjectionCache.latestResult(compatibleWith: searchRequestID) { _, _ in true }
    }

    private var filteredLibraryItems: [LibraryMediaItem] {
        if normalizedSearchQuery.isEmpty { return library.items }
        return displayedSearchResult?.result.items ?? library.items
    }

    private var displayedContentSnapshotRevision: AnyHashable {
        guard !normalizedSearchQuery.isEmpty, let displayed = displayedSearchResult else {
            return AnyHashable(LibraryBrowserContentSnapshot.library(library.itemsRevision))
        }
        // Stable filtering that keeps every input item is exactly the source
        // snapshot; transitioning to/from an all-matching query need not reload.
        if displayed.key.itemsRevision == library.itemsRevision,
           displayed.result.items.count == library.items.count {
            return AnyHashable(LibraryBrowserContentSnapshot.library(library.itemsRevision))
        }
        return AnyHashable(LibraryBrowserContentSnapshot.search(displayed.contentRevision))
    }

    private var rootRemovalTitleKey: String {
        guard let pendingRootRemoval else {
            return "library.source.remove.title"
        }
        switch pendingRootRemoval.kind {
        case .file:
            return "library.video.remove.title"
        case .folder:
            return "library.folder.remove.title"
        }
    }

    private func rootRemovalMessageKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove.message"
        case .folder:
            "library.folder.remove.message"
        }
    }

    private func rootRemovalConfirmKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove.confirm"
        case .folder:
            "library.folder.remove.confirm"
        }
    }

    private var sourceCountText: String {
        let sourceCount = library.sourceRoots.count
            + library.unavailableSources.count
        return localization.localizedFormat(
            "library.source.count",
            sourceCount
        )
    }

    private var sourceNeedsAttention: Bool {
        !library.unavailableSources.isEmpty || library.sourceRoots.contains { root in
            switch library.sourceHealth(for: root).status {
            case .unavailable, .incomplete, .failed: true
            case .notScanned, .scanning, .ready: false
            }
        }
    }

    private var librarySummaryAccessibilityLabel: String {
        let counts = localization.localizedFormat(
            "library.summary.accessibility",
            videoCountText,
            sourceCountText
        )
        return counts
    }

    private var sortAccessibilityValue: String {
        let field = localization.localized(
            library.sort.field.localizedKey
        )
        let direction = localization.localized(
            library.sort.direction.localizedKey
        )
        return "\(field), \(direction)"
    }
}

private enum LibraryBrowserContentSnapshot: Hashable {
    case library(UInt64)
    case search(UInt64)
}
