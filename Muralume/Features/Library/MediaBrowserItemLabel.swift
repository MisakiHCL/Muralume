import SwiftUI

/// Both library items and playlist references use the same visible metadata.
/// Unresolved references expose only facts retained by the reference model.
struct MediaBrowserItemMetadata: Equatable {
    let name: String
    let location: String
    let sourcePath: String
    let fileSize: String?
    let creationDate: String?
    let accessibilityLabel: String

    @MainActor
    init(
        item: LibraryMediaItem?,
        reference: MediaReference? = nil,
        localization: AppLocalizationController
    ) {
        name = item?.displayName ?? reference?.lastKnownDisplayName ?? ""
        sourcePath = item?.url.path ?? reference?.mediaItemID.standardizedMediaPath ?? ""
        let rootName = item?.rootName ?? reference.map {
            URL(fileURLWithPath: $0.mediaItemID.rootPath).lastPathComponent
        } ?? ""
        let directory = item?.relativeDirectory ?? reference.map {
            ($0.mediaItemID.relativePath as NSString).deletingLastPathComponent
        } ?? ""
        location = directory.isEmpty ? rootName : "\(rootName) / \(directory)"
        guard let item else {
            fileSize = nil
            creationDate = nil
            accessibilityLabel = [name, location].filter { !$0.isEmpty }.joined(separator: ", ")
            return
        }
        let sizeText = ByteCountFormatStyle(
            style: .file, allowedUnits: .all, spellsOutZero: false,
            includesActualByteCount: false
        )
        .locale(localization.locale)
        .format(max(item.fileSize, 0))
        let dateText = item.creationDate.map {
            Date.FormatStyle(date: .numeric, time: .shortened, locale: localization.locale)
                .format($0)
        } ?? localization.localized("library.item.creationDate.unavailable")
        fileSize = sizeText
        creationDate = dateText
        let details = item.creationDate == nil
            ? localization.localizedFormat("library.item.metadata.accessibility.dateUnavailable", sizeText)
            : localization.localizedFormat("library.item.metadata.accessibility", sizeText, dateText)
        accessibilityLabel = "\(name), \(location), \(details)"
    }

    func tooltipText(status: String? = nil) -> String {
        [sourcePath, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Rendering is shared; callers retain their own actions, menus, recovery, and IDs.
struct MediaBrowserItemLabel: View {
    let item: LibraryMediaItem?
    let metadata: MediaBrowserItemMetadata
    let isCurrent: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let rowHeight: CGFloat
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let layout: MediaBrowserLayout
    let artworkSize: CGSize
    let isSelecting: Bool
    let isSelected: Bool
    var statusHelp: String? = nil

    var body: some View {
        if layout == .grid {
            gridLabel
        } else {
            listLabel
        }
    }

    private var listLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            artwork(size: MuralumeTheme.Size.mediaItemListArtworkSize(
                rowHeight: rowHeight, width: artworkSize.width
            ))
            metadataLabel
            Spacer(minLength: MuralumeTheme.Spacing.xSmall)
            statusIndicator
                .frame(width: MuralumeTheme.Size.iconLarge, height: MuralumeTheme.Size.iconLarge)
        }
        .padding(MuralumeTheme.Size.mediaItemContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .background {
            MuralumeMediaItemBackground(isCurrent: isCurrent, isSelected: isSelected)
        }
    }

    private var gridLabel: some View {
        artwork(size: artworkSize)
            .overlay {
                MuralumeMediaItemOutline(
                    isCurrent: isCurrent, isSelected: isSelected,
                    cornerRadius: MuralumeTheme.Radius.small, layout: .grid
                )
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting || playbackState == .playing
                    || playbackState == .loading || playbackState == .unavailable {
                    HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        if playbackState == .playing || playbackState == .loading
                            || playbackState == .unavailable {
                            gridBadge { playbackIndicator }
                        }
                        if isSelecting { gridBadge { selectionIndicator } }
                    }
                    .padding(MuralumeTheme.Spacing.xSmall)
                }
            }
    }

    @ViewBuilder
    private func artwork(size: CGSize) -> some View {
        if let item {
            LibraryMediaThumbnail(
                item: item, isCurrent: isCurrent,
                provider: mediaThumbnailProvider, size: size
            )
        } else {
            MediaBrowserItemPlaceholder(isCurrent: isCurrent, size: size)
        }
    }

    private var metadataLabel: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Size.mediaItemMetadataSpacing) {
            Text(verbatim: metadata.name)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: metadata.location)
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let fileSize = metadata.fileSize, let creationDate = metadata.creationDate {
                HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                    Text(verbatim: fileSize)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(verbatim: creationDate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isSelecting {
            selectionIndicator
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

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var playbackIndicator: some View {
        switch playbackState {
        case .unavailable:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MuralumeTheme.Colors.error)
                .help(unavailableHelp)
                .accessibilityHidden(true)
        case .loading:
            ProgressView().controlSize(.small).tint(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)
        case .playing:
            Image(systemName: "waveform")
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)
        case .paused:
            Image(systemName: "play.fill")
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)
        case .available:
            Color.clear
        }
    }

    private var unavailableHelp: Text {
        if let statusHelp { Text(verbatim: statusHelp) }
        else { Text("library.item.unavailable") }
    }

    private func gridBadge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: MuralumeTheme.Size.icon))
            .frame(width: MuralumeTheme.Size.iconLarge, height: MuralumeTheme.Size.iconLarge)
            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
            .accessibilityHidden(true)
    }
}

/// Only pixel thumbnails resize and fill their frame. The symbol keeps its
/// intrinsic aspect ratio in both landscape list artwork and square grid tiles.
struct MediaBrowserItemPlaceholder: View {
    let isCurrent: Bool
    let size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [MuralumeTheme.Colors.panelRaised, MuralumeTheme.Colors.canvas],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(isCurrent
                    ? MuralumeTheme.Colors.controlAccent : MuralumeTheme.Colors.textTertiary)
                .fixedSize()
                .frame(width: MuralumeTheme.Size.iconLarge, height: MuralumeTheme.Size.iconLarge)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: MuralumeTheme.Radius.small, style: .continuous))
        .accessibilityHidden(true)
    }
}
