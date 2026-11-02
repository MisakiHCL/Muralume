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
        let metadata = MediaBrowserItemMetadata(item: item, localization: localization)
        Button(action: play) {
            MediaBrowserItemLabel(
                item: item, metadata: metadata,
                isCurrent: isCurrent, playbackState: playbackState,
                rowHeight: rowHeight, mediaThumbnailProvider: mediaThumbnailProvider,
                layout: layout, artworkSize: artworkSize,
                isSelecting: isSelecting, isSelected: isSelected
            )
        }
        .buttonStyle(MuralumeMediaItemButtonStyle())
        .contentShape(Rectangle())
        .contextMenu { contextMenuContent }
        .help(Text(verbatim: metadata.tooltipText()))
        .accessibilityLabel(Text(verbatim: metadata.accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.libraryItemPrefix
                + item.id.standardizedMediaPath
        )
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

}
