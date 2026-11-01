import SwiftUI

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

struct LibraryMediaRow: View {
    @EnvironmentObject private var localization: AppLocalizationController

    let item: LibraryMediaItem
    let isCurrent: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let rowHeight: CGFloat
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void
    let revealInFinder: () -> Void
    let showInformation: () -> Void
    let reauthorizeSource: (() -> Void)?
    let customPlaylists: [CustomPlaylist]
    let addToPlaylist: (CustomPlaylist.ID) -> Void
    let createPlaylist: () -> Void
    var layout: MediaBrowserLayout = .list
    var artworkSize = CGSize(
        width: MuralumeTheme.Size.playlistArtworkWidth,
        height: MuralumeTheme.Size.playlistArtworkHeight
    )
    var isSelecting = false
    var isSelected = false

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
            if layout == .grid {
                gridLabel
            } else {
                listLabel(
                    location: displayedLocation,
                    fileSize: formattedFileSize,
                    creationDate: formattedCreationDate
                )
            }
        }
        .buttonStyle(MuralumeMediaItemButtonStyle())
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .help(Text(verbatim: item.url.path))
        .accessibilityLabel(Text(verbatim: rowAccessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.libraryItemPrefix
                + item.id.standardizedMediaPath
        )
    }

    private func listLabel(
        location: String,
        fileSize: String,
        creationDate: String
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )

                metadata(
                    location: location,
                    fileSize: fileSize,
                    creationDate: creationDate
                )

                Spacer(minLength: MuralumeTheme.Spacing.xSmall)

                statusIndicator
                    .frame(
                        width: MuralumeTheme.Size.iconLarge,
                        height: MuralumeTheme.Size.iconLarge
                    )
            }
            .padding(MuralumeTheme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background { rowBackground }
    }

    private var gridLabel: some View {
        LibraryMediaThumbnail(
            item: item,
            isCurrent: isCurrent,
            provider: mediaThumbnailProvider,
            size: artworkSize
        )
        .overlay {
            MuralumeMediaItemOutline(
                isCurrent: isCurrent,
                isSelected: isSelected,
                cornerRadius: MuralumeTheme.Radius.small,
                overArtwork: true
            )
        }
        .overlay(alignment: .topTrailing) {
            if isSelecting || playbackState == .playing
                || playbackState == .loading || playbackState == .unavailable {
                HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                    if playbackState == .playing
                        || playbackState == .loading || playbackState == .unavailable {
                        gridBadge { playbackIndicator }
                    }
                    if isSelecting {
                        gridBadge {
                            Image(systemName: isSelected
                                ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                        }
                    }
                }
                .padding(MuralumeTheme.Spacing.xSmall)
            }
        }
    }

    private func gridBadge<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .font(.system(size: MuralumeTheme.Size.icon))
            .frame(
                width: MuralumeTheme.Size.iconLarge,
                height: MuralumeTheme.Size.iconLarge
            )
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .overlay(alignment: .bottomTrailing) {
                    if playbackState == .unavailable {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: MuralumeTheme.Size.menuIndicator))
                            .foregroundStyle(MuralumeTheme.Colors.warning)
                            .background(MuralumeTheme.Colors.panel, in: Circle())
                            .offset(x: MuralumeTheme.Spacing.xSmall, y: MuralumeTheme.Spacing.xSmall)
                    }
                }
                .accessibilityHidden(true)
        } else {
            playbackIndicator
        }
    }

    private var accessibilityValue: String {
        guard isSelecting else {
            return localization.localized(playbackState.accessibilityKey)
        }
        let selected = localization.localized(
            isSelected ? "library.selection.selected" : "library.selection.notSelected"
        )
        guard playbackState != .available else { return selected }
        return "\(selected), \(localization.localized(playbackState.accessibilityKey))"
    }

    private func metadata(
        location: String,
        fileSize: String,
        creationDate: String
    ) -> some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
            Text(item.displayName)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(location)
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                Text(verbatim: fileSize)
                    .fixedSize(horizontal: true, vertical: false)

                Text(verbatim: "·")
                    .accessibilityHidden(true)

                Text(verbatim: creationDate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var playbackIndicator: some View {
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
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
        case .paused:
            Image(systemName: "play.fill")
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
        case .available:
            Color.clear
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(
            cornerRadius: MuralumeTheme.Radius.medium,
            style: .continuous
        )
        .fill(
            isCurrent ? MuralumeTheme.Colors.controlHover
                : isSelected ? MuralumeTheme.Colors.controlFill
                : MuralumeTheme.Colors.controlFill.opacity(0.36)
        )
        .overlay {
            MuralumeMediaItemOutline(
                isCurrent: isCurrent,
                isSelected: isSelected,
                cornerRadius: MuralumeTheme.Radius.medium
            )
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let reauthorizeSource {
            Button(action: reauthorizeSource) {
                Label(
                    "library.item.reauthorizeSource",
                    systemImage: "folder.badge.questionmark"
                )
            }

            Divider()
        }

        Button(action: showInformation) {
            Label("videoInfo.menu", systemImage: "info.circle")
        }

        Button(action: revealInFinder) {
            Label("library.item.revealInFinder", systemImage: "folder")
        }

        Menu("playlists.addTo") {
            ForEach(customPlaylists) { playlist in
                let isAdded = playlist.contains(mediaItem: item)
                Button {
                    addToPlaylist(playlist.id)
                } label: {
                    HStack {
                        Text(verbatim: playlist.name)
                        if isAdded {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .disabled(isAdded)
                .accessibilityLabel(
                    Text(
                        verbatim: playlistMenuAccessibilityLabel(
                            playlist,
                            isAdded: isAdded
                        )
                    )
                )
            }
            if !customPlaylists.isEmpty { Divider() }
            Button("playlists.new", action: createPlaylist)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.playlistCreateFromSelectionButton
                )
        }
    }

    private func playlistMenuAccessibilityLabel(
        _ playlist: CustomPlaylist,
        isAdded: Bool
    ) -> String {
        guard isAdded else {
            return playlist.name
        }
        return localization.localizedFormat(
            "playlists.added.accessibility",
            playlist.name
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
