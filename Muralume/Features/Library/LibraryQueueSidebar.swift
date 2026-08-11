import Combine
import SwiftUI

private extension LibrarySidebarSection {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .mediaLibrary:
            "library.playlist"
        case .playQueue:
            "queue.title"
        }
    }

    var systemImage: String {
        switch self {
        case .mediaLibrary:
            "square.grid.2x2"
        case .playQueue:
            "list.bullet.rectangle"
        }
    }
}

struct LibraryQueueSidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    @EnvironmentObject private var localization: AppLocalizationController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pendingRootRemoval: MediaLibraryRoot?
    @State private var isSidebarTitleHovered = false
    @State private var playbackStatus: LibraryPlaybackStatus
    @Binding private var sidebarSection: LibrarySidebarSection
    let playbackQueueFocusRequest: UInt64
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isEditing: Bool
    let setEditing: (Bool) -> Void
    let addMedia: () -> Void
    let retryUnavailableSourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void
    let canRestoreDynamicDesktop: Bool
    let addTemporaryItemsToLibrary: () -> Void
    let restoreDynamicDesktop: () -> Void
    let playLibraryItem: (LibraryMediaItem) -> Void
    let revealMediaInFinder: (URL) -> Void
    let dismiss: () -> Void

    init(
        library: MediaLibraryCoordinator,
        playback: PlaybackCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        sidebarSection: Binding<LibrarySidebarSection>,
        playbackQueueFocusRequest: UInt64,
        isEditing: Bool,
        setEditing: @escaping (Bool) -> Void,
        addMedia: @escaping () -> Void,
        retryUnavailableSourceAccess: @escaping () -> Void,
        reauthorizeMediaSources: @escaping () -> Void,
        canRestoreDynamicDesktop: Bool,
        addTemporaryItemsToLibrary: @escaping () -> Void,
        restoreDynamicDesktop: @escaping () -> Void,
        playLibraryItem: @escaping (LibraryMediaItem) -> Void,
        revealMediaInFinder: @escaping (URL) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.library = library
        self.playback = playback
        self.mediaThumbnailProvider = mediaThumbnailProvider
        _sidebarSection = sidebarSection
        self.playbackQueueFocusRequest = playbackQueueFocusRequest
        self.isEditing = isEditing
        self.setEditing = setEditing
        self.addMedia = addMedia
        self.retryUnavailableSourceAccess = retryUnavailableSourceAccess
        self.reauthorizeMediaSources = reauthorizeMediaSources
        self.canRestoreDynamicDesktop = canRestoreDynamicDesktop
        self.addTemporaryItemsToLibrary = addTemporaryItemsToLibrary
        self.restoreDynamicDesktop = restoreDynamicDesktop
        self.playLibraryItem = playLibraryItem
        self.revealMediaInFinder = revealMediaInFinder
        self.dismiss = dismiss
        _playbackStatus = State(
            initialValue: LibraryPlaybackStatus(playback: playback)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            header

            sidebarStatusBar
                .frame(height: MuralumeTheme.Size.playlistStatusBarHeight)

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
        .onReceive(playbackStatusPublisher) { status in
            playbackStatus = status
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            sidebarTitle

            Spacer(minLength: MuralumeTheme.Spacing.small)

            if !isEditing, sidebarSection == .mediaLibrary {
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

            if sidebarSection == .mediaLibrary, !library.roots.isEmpty {
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
            sidebarTitleLabel(showsDisclosureIndicator: false)
                .padding(.horizontal, MuralumeTheme.Spacing.small)
                .padding(.vertical, MuralumeTheme.Spacing.small)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.libraryTitle
                )
        } else {
            Menu {
                ForEach(LibrarySidebarSection.allCases, id: \.self) { section in
                    Button {
                        sidebarSection = section
                    } label: {
                        if sidebarSection == section {
                            Label(section.localizedKey, systemImage: "checkmark")
                        } else {
                            Text(section.localizedKey)
                        }
                    }
                    .accessibilityAddTraits(
                        sidebarSection == section ? .isSelected : []
                    )
                    .accessibilityIdentifier(
                        accessibilityIdentifier(for: section)
                    )
                }
            } label: {
                sidebarTitleLabel(showsDisclosureIndicator: true)
            }
            .menuStyle(.button)
            .buttonStyle(
                MuralumeToolbarButtonStyle(
                    kind: isSidebarTitleHovered ? .selected : .standard
                )
            )
            .menuIndicator(.hidden)
            .onHover { isHovered in
                isSidebarTitleHovered = isHovered
            }
            .onDisappear {
                isSidebarTitleHovered = false
            }
            .help(Text("queue.navigation"))
            .accessibilityLabel(Text("queue.navigation"))
            .accessibilityValue(Text(sidebarSection.localizedKey))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.libraryTitle
            )
        }
    }

    private func sidebarTitleLabel(
        showsDisclosureIndicator: Bool
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.xSmall) {
            Image(systemName: sidebarSection.systemImage)
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

            Text(sidebarSection.localizedKey)
                .font(.headline)
                .lineLimit(1)

            if showsDisclosureIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.menuIndicator,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        isSidebarTitleHovered
                            ? MuralumeTheme.Colors.textPrimary
                            : MuralumeTheme.Colors.textSecondary
                    )
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .contentShape(Rectangle())
    }

    private var sidebarHideLabelKey: String {
        sidebarSection == .mediaLibrary
            ? "library.playlist.hide"
            : "queue.hide"
    }

    private func accessibilityIdentifier(
        for section: LibrarySidebarSection
    ) -> String {
        switch section {
        case .mediaLibrary:
            MuralumeAccessibilityIdentifier.mediaLibrarySectionMenuItem
        case .playQueue:
            MuralumeAccessibilityIdentifier.playQueueSectionMenuItem
        }
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

    private var refreshActionLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.xSmall) {
            Image(systemName: "arrow.clockwise")
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )

            Text("library.refresh")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var libraryStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            librarySummary
                .frame(maxWidth: .infinity, alignment: .leading)

            if !library.items.isEmpty,
               library.sourceAccessState.hasUnavailableSources {
                Button {
                    retryUnavailableSourceAccess()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(
                            .system(
                                size: MuralumeTheme.Size.icon,
                                weight: .semibold
                            )
                        )
                        .frame(
                            width: MuralumeTheme.Size.control,
                            height: MuralumeTheme.Size.control
                        )
                }
                .buttonStyle(.plain)
                .disabled(!library.canRetrySourceAccess)
                .help(Text("library.sourceAccess.retry"))
                .accessibilityLabel(Text("library.sourceAccess.retry"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.retrySourceAccessButton
                )
            }

            if !library.items.isEmpty,
               library.sourceAccessState == .partiallyUnavailable {
                reauthorizeSourceAccessButton
            }

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
            editorRefreshStatus
                .frame(maxWidth: .infinity, alignment: .leading)

            if library.sourceAccessState == .partiallyUnavailable {
                reauthorizeSourceAccessButton
            }

            Button {
                library.refresh()
            } label: {
                refreshActionLabel
            }
            .buttonStyle(
                MuralumeToolbarButtonStyle(
                    width: MuralumeTheme.Size.playlistRefreshActionWidth
                )
            )
            .disabled(!library.canRefresh)
            .help(Text("library.refresh"))
            .accessibilityLabel(Text("library.refresh"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.refreshLibraryButton
            )
        }
    }

    private var reauthorizeSourceAccessButton: some View {
        Button {
            reauthorizeMediaSources()
        } label: {
            Image(systemName: "key.horizontal")
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )
                .frame(
                    width: MuralumeTheme.Size.control,
                    height: MuralumeTheme.Size.control
                )
        }
        .buttonStyle(.plain)
        .help(Text("library.sourceAccess.reauthorize"))
        .accessibilityLabel(Text("library.sourceAccess.reauthorize"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.reauthorizeSourcesButton
        )
    }

    private var rootEditor: some View {
        VStack(alignment: .leading) {
            ScrollView {
                LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                    ForEach(library.roots) { root in
                        HStack(spacing: MuralumeTheme.Spacing.medium) {
                            Image(systemName: sourceIcon(for: root))
                                .font(.system(size: MuralumeTheme.Size.icon))
                                .foregroundStyle(
                                    MuralumeTheme.Colors.controlAccent
                                )

                            VStack(
                                alignment: .leading,
                                spacing: MuralumeTheme.Spacing.xSmall
                            ) {
                                Text(verbatim: root.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.textPrimary
                                    )
                                    .lineLimit(1)

                                Text(verbatim: root.url.path)
                                    .font(.caption)
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.textTertiary
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: MuralumeTheme.Spacing.small)

                            Button {
                                pendingRootRemoval = root
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(
                                        .system(
                                            size: MuralumeTheme.Size.iconLarge,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.error
                                    )
                                    .frame(
                                        width: MuralumeTheme.Size.control,
                                        height: MuralumeTheme.Size.control
                                    )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .help(
                                Text(
                                    LocalizedStringKey(
                                        rootRemovalLabelKey(for: root)
                                    )
                                )
                            )
                            .accessibilityLabel(
                                Text(
                                    LocalizedStringKey(
                                        rootRemovalLabelKey(for: root)
                                    )
                                )
                            )
                        }
                        .padding(MuralumeTheme.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(
                                cornerRadius: MuralumeTheme.Radius.medium,
                                style: .continuous
                            )
                            .fill(
                                MuralumeTheme.Colors.controlFill.opacity(0.52)
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: MuralumeTheme.Radius.medium,
                                    style: .continuous
                                )
                                .stroke(
                                    MuralumeTheme.Colors.border,
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, MuralumeTheme.Spacing.xSmall)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var editorRefreshStatus: some View {
        switch library.scanState {
        case .idle:
            Text(
                library.sourceAccessState == .temporarilyUnavailable
                    ? "library.sourceAccess.unavailable.short"
                    : "library.summary.empty"
            )
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .scanning:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .accessibilityHidden(true)
                Text("library.scanning")
            }
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .ready:
            if library.sourceAccessState == .partiallyUnavailable {
                Label(
                    "library.sourceAccess.partial",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .foregroundStyle(MuralumeTheme.Colors.warning)
                .lineLimit(1)
            } else {
                Text(videoCountText)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        case .failed:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                Text("library.scan.failed")
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        }
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

    @ViewBuilder
    private var librarySummary: some View {
        switch library.scanState {
        case .idle:
            Text(
                library.sourceAccessState == .temporarilyUnavailable
                    ? "library.sourceAccess.unavailable.short"
                    : "library.summary.empty"
            )
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .scanning:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                Text("library.scanning")
            }
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .ready:
            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                Text(videoCountText)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                if library.sourceAccessState == .partiallyUnavailable {
                    Label(
                        "library.sourceAccess.partial",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .lineLimit(1)
                } else if let sourceText {
                    Text(sourceText)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .failed:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                Text("library.scan.failed")
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                Button("library.retry") {
                    library.refresh()
                }
                .buttonStyle(.link)
            }
        }
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
                    width: MuralumeTheme.Size.control,
                    height: MuralumeTheme.Size.control
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
                retrySourceAccess: retryUnavailableSourceAccess,
                reauthorizeMediaSources: reauthorizeMediaSources
            )
        } else {
            FixedHeightVirtualizedTable(
                items: library.items,
                snapshotRevision: library.itemsRevision,
                rowContentRevision: LibraryPlaylistRowContentRevision(
                    currentItemID: library.currentItemID,
                    unavailableItemsRevision:
                        library.unavailableItemsRevision,
                    playbackState: playbackStatus.rowState
                ),
                scrollTargetID: library.currentItemID,
                rowHeight: playlistRowHeight,
                rowSpacing: MuralumeTheme.Spacing.xSmall,
                verticalContentInset: MuralumeTheme.Spacing.xSmall
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
        localization.localizedFormat(
            "library.video.count",
            library.items.count
        )
    }

    private func sourceIcon(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "film.fill"
        case .folder:
            "folder.fill"
        }
    }

    private func rootRemovalLabelKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove"
        case .folder:
            "library.folder.remove"
        }
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

    private var sourceText: String? {
        guard !library.roots.isEmpty else {
            return nil
        }
        if library.roots.count == 1 {
            return library.roots[0].displayName
        }
        return localization.localizedFormat(
            "library.source.count",
            library.roots.count
        )
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

private struct LibraryPlaybackStatus: Equatable {
    let rowState: LibraryMediaRowPlaybackState

    @MainActor
    init(playback: PlaybackCoordinator) {
        self.init(
            readiness: playback.readiness,
            isPlaybackRequested: playback.isPlaybackRequested,
            hasPlayableMedia: playback.hasPlayableMedia
        )
    }

    init(
        readiness: PlaybackReadiness,
        isPlaybackRequested: Bool,
        hasPlayableMedia: Bool
    ) {
        if hasPlayableMedia {
            rowState = isPlaybackRequested ? .playing : .paused
            return
        }

        switch readiness {
        case .loading:
            rowState = .loading
        case .ready:
            rowState = isPlaybackRequested ? .playing : .paused
        case .empty, .failed:
            rowState = .paused
        }
    }
}

private struct LibraryPlaylistRowContentRevision: Hashable {
    let currentItemID: LibraryMediaItem.ID?
    let unavailableItemsRevision: UInt64
    let playbackState: LibraryMediaRowPlaybackState
}

enum LibraryMediaRowPlaybackState: Hashable {
    case available
    case loading
    case playing
    case paused
    case unavailable

    var accessibilityKey: String {
        switch self {
        case .available:
            "queue.item.play"
        case .loading:
            "queue.item.loading"
        case .playing:
            "queue.item.playing"
        case .paused:
            "queue.item.paused"
        case .unavailable:
            "queue.item.unavailable"
        }
    }
}

private struct LibraryMediaRow: View {
    @EnvironmentObject private var localization: AppLocalizationController

    let item: LibraryMediaItem
    let isCurrent: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let rowHeight: CGFloat
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void
    let revealInFinder: () -> Void

    var body: some View {
        let displayedLocation = locationText
        let formattedFileSize = fileSizeText
        let formattedCreationDate = creationDateText
        let rowAccessibilityLabel = accessibilityLabel(
            locationText: displayedLocation,
            fileSizeText: formattedFileSize,
            creationDateText: formattedCreationDate
        )

        Button(action: play) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )

                VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                    Text(item.displayName)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(displayedLocation)
                        .font(.caption)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        Text(verbatim: formattedFileSize)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(verbatim: "·")
                            .accessibilityHidden(true)

                        Text(verbatim: formattedCreationDate)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                }

                Spacer(minLength: MuralumeTheme.Spacing.xSmall)

                ZStack {
                    switch playbackState {
                    case .unavailable:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(MuralumeTheme.Colors.error)
                            .help(Text("library.item.unavailable"))
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                            .tint(MuralumeTheme.Colors.controlAccent)
                    case .playing:
                        Image(systemName: "waveform")
                            .foregroundStyle(
                                MuralumeTheme.Colors.controlAccent
                            )
                    case .paused:
                        Image(systemName: "play.fill")
                            .foregroundStyle(
                                MuralumeTheme.Colors.controlAccent
                            )
                    case .available:
                        Color.clear
                    }
                }
                .frame(
                    width: MuralumeTheme.Size.iconLarge,
                    height: MuralumeTheme.Size.iconLarge
                )
            }
            .padding(MuralumeTheme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
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
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(
                        isCurrent
                            ? MuralumeTheme.Colors.borderStrong
                            : Color.clear,
                        lineWidth: 1
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: revealInFinder) {
                Label(
                    "library.item.revealInFinder",
                    systemImage: "folder"
                )
            }
        }
        .help(Text(verbatim: item.relativePath))
        .accessibilityLabel(Text(verbatim: rowAccessibilityLabel))
        .accessibilityValue(
            Text(
                LocalizedStringKey(playbackState.accessibilityKey)
            )
        )
    }

    private var locationText: String {
        guard !item.relativeDirectory.isEmpty else {
            return item.rootName
        }
        return "\(item.rootName) / \(item.relativeDirectory)"
    }

    private var fileSizeText: String {
        ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false
        )
            .locale(localization.locale)
            .format(max(item.fileSize, 0))
    }

    private var creationDateText: String {
        guard let creationDate = item.creationDate else {
            return localization.localized(
                "library.item.creationDate.unavailable"
            )
        }

        return Date.FormatStyle(
            date: .numeric,
            time: .shortened,
            locale: localization.locale
        )
        .format(creationDate)
    }

    private func accessibilityLabel(
        locationText: String,
        fileSizeText: String,
        creationDateText: String
    ) -> String {
        let metadata: String
        if item.creationDate == nil {
            metadata = localization.localizedFormat(
                "library.item.metadata.accessibility.dateUnavailable",
                fileSizeText
            )
        } else {
            metadata = localization.localizedFormat(
                "library.item.metadata.accessibility",
                fileSizeText,
                creationDateText
            )
        }
        return "\(item.displayName), \(locationText), \(metadata)"
    }
}

private struct LibrarySidebarEmptyState: View {
    let scanState: MediaLibraryScanState
    let sourceAccessState: MediaLibrarySourceAccessState
    let canRetrySourceAccess: Bool
    let retrySourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void

    private var sourceAccessIsUnavailable: Bool {
        sourceAccessState.hasUnavailableSources
    }

    private var sourceAccessUnavailableTitleKey: String {
        sourceAccessState == .partiallyUnavailable
            ? "library.sourceAccess.partial"
            : "library.sourceAccess.unavailable.title"
    }

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)

            Image(
                systemName: sourceAccessIsUnavailable
                    ? "externaldrive.badge.exclamationmark"
                    : scanState == .scanning
                        ? "magnifyingglass"
                        : "plus.rectangle.on.folder"
            )
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            .accessibilityHidden(true)

            Text(
                LocalizedStringKey(
                    sourceAccessIsUnavailable
                        && scanState != .scanning
                        ? sourceAccessUnavailableTitleKey
                        : "library.playlist.empty"
                )
            )
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)

            if sourceAccessIsUnavailable,
               scanState != .scanning {
                Text(
                    LocalizedStringKey(
                        sourceAccessState == .partiallyUnavailable
                            ? "library.sourceAccess.partial.detail"
                            : "library.sourceAccess.unavailable.detail"
                    )
                )
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            }

            if sourceAccessIsUnavailable,
               scanState != .scanning {
                HStack(spacing: MuralumeTheme.Spacing.small) {
                    Button("library.sourceAccess.retry") {
                        retrySourceAccess()
                    }
                    .buttonStyle(
                        MuralumeToolbarButtonStyle(
                            width: MuralumeTheme.Size
                                .playlistRefreshActionWidth
                        )
                    )
                    .disabled(!canRetrySourceAccess)
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier
                            .retrySourceAccessButton
                    )

                    Button("library.sourceAccess.reauthorize") {
                        reauthorizeMediaSources()
                    }
                    .buttonStyle(
                        MuralumeToolbarButtonStyle(
                            width: MuralumeTheme.Size
                                .playlistRefreshActionWidth
                        )
                    )
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier
                            .reauthorizeSourcesButton
                    )
                }
            }

            Spacer(minLength: MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }
}

private extension MediaLibrarySortField {
    var localizedKey: String {
        switch self {
        case .name:
            "library.sort.name"
        case .creationDate:
            "library.sort.creationDate"
        case .fileSize:
            "library.sort.fileSize"
        }
    }
}

private extension MediaLibrarySortDirection {
    var localizedKey: String {
        switch self {
        case .ascending:
            "library.sort.ascending"
        case .descending:
            "library.sort.descending"
        }
    }
}
