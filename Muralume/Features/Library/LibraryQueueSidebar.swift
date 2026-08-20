import Combine
import SwiftUI

struct LibraryQueueSidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingRootRemoval: MediaLibraryRoot?
    @State private var pendingUnavailableSourceRemoval:
        UnavailableMediaSource?
    @State private var playbackStatus: LibraryPlaybackStatus
    @State private var searchScrollToTopRequest: UInt64 = 0
    @State private var searchProjectionCache =
        MediaLibrarySearchProjectionCache()
    @Binding private var sidebarSection: LibrarySidebarSection
    @Binding private var searchQuery: String
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
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void

    init(
        library: MediaLibraryCoordinator,
        playback: PlaybackCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        sidebarSection: Binding<LibrarySidebarSection>,
        searchQuery: Binding<String>,
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
        revealMediaInFinder: @escaping (URL) -> Void,
        showVideoInformation: @escaping (LibraryMediaItem) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.library = library
        self.playback = playback
        self.mediaThumbnailProvider = mediaThumbnailProvider
        _sidebarSection = sidebarSection
        _searchQuery = searchQuery
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
        self.revealMediaInFinder = revealMediaInFinder
        self.showVideoInformation = showVideoInformation
        self.dismiss = dismiss
        _playbackStatus = State(
            initialValue: LibraryPlaybackStatus(playback: playback)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                let removesLastRoot = library.roots.count == 1
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
                if library.roots.isEmpty,
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
        .onReceive(playbackStatusPublisher) { status in
            playbackStatus = status
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
               !library.roots.isEmpty || !library.unavailableSources.isEmpty {
                Button {
                    setEditing(!isEditing)
                } label: {
                    headerActionIcon(
                        systemImage: isEditing ? "checkmark" : "pencil"
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
                            isEditing ? "library.done" : "library.edit"
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

            sortMenu
        }
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
            librarySummary(showsInlineRetry: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rootEditor: some View {
        LibraryRootEditor(
            roots: library.roots,
            unavailableSources: library.unavailableSources,
            requestRemoval: { root in
                pendingRootRemoval = root
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
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .frame(
                    width: MuralumeTheme.Size.compactControl,
                    height: MuralumeTheme.Size.compactControl
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                    _ = library.addCurrentTemporaryItemToLibrary()
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
        } else if filteredLibraryItems.isEmpty {
            LibrarySearchEmptyState {
                searchQuery = ""
            }
        } else {
            FixedHeightVirtualizedTable(
                items: filteredLibraryItems,
                snapshotRevision: LibraryPlaylistSnapshotRevision(
                    itemsRevision: library.itemsRevision,
                    query: normalizedSearchQuery
                ),
                rowContentRevision: LibraryPlaylistRowContentRevision(
                    currentItemID: library.currentItemID,
                    unavailableItemsRevision:
                        library.unavailableItemsRevision,
                    playbackState: playbackStatus.rowState,
                    playlistCollectionRevision:
                        customPlaylistsRevision,
                    playlistMenuEntries: customPlaylists.map {
                        LibraryPlaylistMenuEntryRevision(
                            id: $0.id,
                            name: $0.name
                        )
                    }
                ),
                scrollTargetID: normalizedSearchQuery.isEmpty
                    ? library.currentItemID
                    : nil,
                scrollToTopRequest: normalizedSearchQuery.isEmpty
                    ? nil
                    : searchScrollToTopRequest,
                rowHeight: playlistRowHeight,
                rowSpacing: MuralumeTheme.Spacing.xSmall,
                verticalContentInset:
                    MuralumeTheme.Size.playlistContentInset
            ) { item in
                LibraryMediaRow(
                    item: item,
                    isCurrent: library.currentItemID == item.id,
                    playbackState: playbackState(for: item),
                    rowHeight: playlistRowHeight,
                    mediaThumbnailProvider: mediaThumbnailProvider,
                    play: {
                        playLibraryItem(item)
                        dismiss()
                    },
                    revealInFinder: {
                        revealMediaInFinder(item.url)
                    },
                    showInformation: {
                        showVideoInformation(item)
                    },
                    reauthorizeSource: reauthorizeSourceAction(for: item),
                    customPlaylists: customPlaylists,
                    addToPlaylist: { playlistID in
                        addLibraryItemToPlaylist(item, playlistID)
                    }
                )
                // NSHostingView is a separate SwiftUI root.
                .environmentObject(localization)
            }
            .scrollIndicators(.visible)
            .accessibilityLabel(Text("library.playlist"))
        }
    }

    private func playbackState(
        for item: LibraryMediaItem
    ) -> LibraryMediaRowPlaybackState {
        if library.unavailableItemIDs.contains(item.id) {
            return .unavailable
        }
        guard library.currentItemID == item.id else {
            return .available
        }

        return playbackStatus.rowState
    }

    private func reauthorizeSourceAction(
        for item: LibraryMediaItem
    ) -> (() -> Void)? {
        guard library.unavailableItemIDs.contains(item.id),
              let source = library.unavailableSource(for: item) else {
            return nil
        }
        return {
            reauthorizeMediaSource(source)
        }
    }

    private var playlistRowHeight: CGFloat {
        MuralumeTheme.Size.playlistRowHeight(for: dynamicTypeSize)
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
        if !normalizedSearchQuery.isEmpty {
            return localization.localizedFormat(
                "library.search.results",
                filteredLibraryItems.count,
                library.items.count
            )
        }
        return localization.localizedFormat(
            library.items.count == 1
                ? "library.video.count.one"
                : "library.video.count",
            library.items.count
        )
    }

    private var normalizedSearchQuery: String {
        searchProjection.search.query
    }

    private var filteredLibraryItems: [LibraryMediaItem] {
        searchProjection.items
    }

    private var searchProjection: MediaLibrarySearchProjection {
        searchProjectionCache.projection(
            query: searchQuery,
            itemsRevision: library.itemsRevision,
            items: library.items
        )
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
        let sourceCount = library.roots.count
            + library.unavailableSources.count
        return localization.localizedFormat(
            sourceCount == 1
                ? "library.source.count.one"
                : "library.source.count",
            sourceCount
        )
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
