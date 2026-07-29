import SwiftUI

struct LibraryQueueSidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playback: PlaybackCoordinator
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var isEditing = false
    @State private var pendingRootRemoval: MediaLibraryRoot?
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let addFolders: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            header

            if isEditing {
                rootEditor
            } else {
                libraryStatusBar

                Divider()
                    .overlay(MuralumeTheme.Colors.border)

                playlistContent

                if let position = library.currentPosition {
                    queueFooter(position: position)
                }
            }
        }
        .padding(MuralumeTheme.Spacing.medium)
        .frame(width: MuralumeTheme.Size.playlistOverlayWidth)
        .frame(maxHeight: .infinity)
        .muralumePanel(style: .playerOverlay)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySidebar
        )
        .alert(
            "library.folder.remove.title",
            isPresented: rootRemovalAlertIsPresented,
            presenting: pendingRootRemoval
        ) { root in
            Button("library.folder.remove.confirm", role: .destructive) {
                let removesLastRoot = library.roots.count == 1
                library.removeRoot(root)
                pendingRootRemoval = nil
                if removesLastRoot {
                    isEditing = false
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingRootRemoval = nil
            }
        } message: { root in
            Text(
                verbatim: localization.localizedFormat(
                    "library.folder.remove.message",
                    root.displayName
                )
            )
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Label("library.playlist", systemImage: "list.bullet")
                .font(.headline)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.libraryTitle
                )

            Spacer(minLength: MuralumeTheme.Spacing.small)

            if !library.roots.isEmpty {
                Button {
                    isEditing.toggle()
                } label: {
                    Text(
                        LocalizedStringKey(
                            isEditing ? "library.done" : "library.edit"
                        )
                    )
                }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.editLibraryButton
                )
            }

            if !isEditing {
                Button(action: addFolders) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(MuralumeControlButtonStyle(kind: .accent))
                .help(Text(LocalizedStringKey(addFolderLabelKey)))
                .accessibilityLabel(
                    Text(LocalizedStringKey(addFolderLabelKey))
                )
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.addFolderButton
                )
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("library.playlist.hide"))
            .accessibilityLabel(Text("library.playlist.hide"))
        }
        .frame(
            minHeight: MuralumeTheme.Size.control,
            alignment: .center
        )
    }

    private var libraryStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            librarySummary
                .frame(maxWidth: .infinity, alignment: .leading)

            sortMenu
        }
    }

    private var rootEditor: some View {
        ScrollView {
            LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                ForEach(library.roots) { root in
                    HStack(spacing: MuralumeTheme.Spacing.medium) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: MuralumeTheme.Size.icon))
                            .foregroundStyle(MuralumeTheme.Colors.controlAccent)

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
                                .foregroundStyle(MuralumeTheme.Colors.error)
                                .frame(
                                    width: MuralumeTheme.Size.control,
                                    height: MuralumeTheme.Size.control
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .help(Text("library.folder.remove"))
                        .accessibilityLabel(Text("library.folder.remove"))
                    }
                    .padding(MuralumeTheme.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(
                            cornerRadius: MuralumeTheme.Radius.medium,
                            style: .continuous
                        )
                        .fill(MuralumeTheme.Colors.controlFill.opacity(0.52))
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
            Text("library.summary.empty")
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
                if let rootText {
                    Text(rootText)
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
        if library.items.isEmpty {
            LibrarySidebarEmptyState(
                scanState: library.scanState,
                hasRoots: !library.roots.isEmpty
            )
        } else {
            ScrollView {
                LazyVStack(spacing: MuralumeTheme.Spacing.xSmall) {
                    ForEach(library.items) { item in
                        LibraryMediaRow(
                            item: item,
                            isCurrent: library.currentItemID == item.id,
                            playbackState: playbackState(for: item),
                            mediaThumbnailProvider: mediaThumbnailProvider,
                            play: {
                                library.play(item)
                                dismiss()
                            }
                        )
                    }
                }
                .padding(.vertical, MuralumeTheme.Spacing.xSmall)
            }
            .scrollIndicators(.visible)
            .accessibilityLabel(Text("library.playlist"))
        }
    }

    private func queueFooter(position: Int) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Image(
                systemName: library.playbackOrder == .ordered
                    ? "list.number"
                    : "shuffle"
            )
            Text(
                localization.localizedFormat(
                    "queue.position",
                    position,
                    library.queueCount
                )
            )
            Spacer(minLength: MuralumeTheme.Spacing.small)
            Text(
                localization.localizedFormat(
                    "queue.round",
                    library.queueRoundNumber
                )
            )
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        .padding(.horizontal, MuralumeTheme.Spacing.small)
        .frame(height: MuralumeTheme.Size.queueFooterHeight)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill)
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

        switch playback.readiness {
        case .loading:
            return .loading
        case .ready:
            return playback.isActuallyPlaying ? .playing : .paused
        case .empty, .failed:
            return .paused
        }
    }

    private var videoCountText: String {
        localization.localizedFormat(
            "library.video.count",
            library.items.count
        )
    }

    private var addFolderLabelKey: String {
        library.roots.isEmpty
            ? "library.add.folder"
            : "library.add.another.folder"
    }

    private var rootText: String? {
        guard !library.roots.isEmpty else {
            return nil
        }
        if library.roots.count == 1 {
            return library.roots[0].displayName
        }
        return localization.localizedFormat(
            "library.folder.count",
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

private enum LibraryMediaRowPlaybackState {
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
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                currentIndicator
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

                    Text(locationText)
                        .font(.caption)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        Text(verbatim: fileSizeText)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(verbatim: "·")
                            .accessibilityHidden(true)

                        Text(verbatim: creationDateText)
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
            .padding(.vertical, MuralumeTheme.Spacing.small)
            .padding(.trailing, MuralumeTheme.Spacing.small)
            .frame(
                maxWidth: .infinity,
                minHeight: MuralumeTheme.Size.playlistRowHeight,
                alignment: .leading
            )
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
        .help(Text(verbatim: item.relativePath))
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(
            Text(
                LocalizedStringKey(playbackState.accessibilityKey)
            )
        )
    }

    private var currentIndicator: some View {
        RoundedRectangle(
            cornerRadius: MuralumeTheme.Radius.small,
            style: .continuous
        )
        .fill(isCurrent ? MuralumeTheme.brandGradient : LinearGradient(
            colors: [.clear],
            startPoint: .top,
            endPoint: .bottom
        ))
        .frame(width: MuralumeTheme.Spacing.xSmall)
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

    private var accessibilityLabel: String {
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
    let hasRoots: Bool

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)

            Image(
                systemName: scanState == .scanning
                    ? "magnifyingglass"
                    : "folder.badge.plus"
            )
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            .accessibilityHidden(true)

            Text(
                LocalizedStringKey(
                    scanState == .scanning
                        ? "library.scanning"
                        : hasRoots
                            ? "library.empty.title"
                            : "media.none.title"
                )
            )
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)

            if scanState != .scanning {
                Text(
                    LocalizedStringKey(
                        hasRoots
                            ? "library.empty.detail"
                            : "media.none.detail"
                    )
                )
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
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
