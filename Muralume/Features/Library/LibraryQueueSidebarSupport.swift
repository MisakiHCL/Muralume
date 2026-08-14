import SwiftUI

enum LibrarySidebarNavigationItem: CaseIterable, Hashable {
    case mediaLibrary
    case playlists
    case nowPlaying

    var localizedKey: LocalizedStringKey {
        switch self {
        case .mediaLibrary:
            "library.playlist"
        case .playlists:
            "playlists.title"
        case .nowPlaying:
            "queue.title"
        }
    }

    var systemImage: String {
        switch self {
        case .mediaLibrary:
            "square.grid.2x2"
        case .playlists:
            "rectangle.stack.fill"
        case .nowPlaying:
            "list.bullet.rectangle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .mediaLibrary:
            MuralumeAccessibilityIdentifier.mediaLibrarySectionMenuItem
        case .playlists:
            MuralumeAccessibilityIdentifier.playlistsSectionMenuItem
        case .nowPlaying:
            MuralumeAccessibilityIdentifier.playQueueSectionMenuItem
        }
    }
}

extension LibrarySidebarDestination {
    var navigationItem: LibrarySidebarNavigationItem {
        switch self {
        case .mediaLibrary:
            .mediaLibrary
        case .playlists, .playlist:
            .playlists
        case .playQueue:
            .nowPlaying
        }
    }
}

struct LibrarySidebarNavigationMenu: View {
    let selection: LibrarySidebarNavigationItem
    let select: (LibrarySidebarNavigationItem) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(LibrarySidebarNavigationItem.allCases, id: \.self) {
                item in
                Toggle(
                    isOn: Binding(
                        get: { selection == item },
                        set: { isSelected in
                            guard isSelected else { return }
                            select(item)
                        }
                    )
                ) {
                    Text(item.localizedKey)
                }
                .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                Image(systemName: selection.systemImage)
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

                Text(selection.localizedKey)
                    .font(.headline)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.menuIndicator,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        isHovered
                            ? MuralumeTheme.Colors.textPrimary
                            : MuralumeTheme.Colors.textSecondary
                    )
                    .accessibilityHidden(true)
            }
            .foregroundStyle(MuralumeTheme.Colors.textPrimary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(
            MuralumeToolbarButtonStyle(
                kind: isHovered ? .selected : .standard
            )
        )
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .help(Text("queue.navigation"))
        .accessibilityLabel(Text("queue.navigation"))
        .accessibilityValue(Text(selection.localizedKey))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.libraryTitle
        )
    }
}

struct LibraryPlaylistRowContentRevision: Hashable {
    let currentItemID: LibraryMediaItem.ID?
    let unavailableItemsRevision: UInt64
    let playbackState: LibraryMediaRowPlaybackState
    let playlistCollectionRevision: UInt64
    let playlistMenuEntries: [LibraryPlaylistMenuEntryRevision]
}

struct LibraryPlaylistMenuEntryRevision: Hashable {
    let id: CustomPlaylist.ID
    let name: String
}

struct LibraryPlaylistSnapshotRevision: Hashable {
    let itemsRevision: UInt64
    let query: String
}

extension MediaLibrarySortField {
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

extension MediaLibrarySortDirection {
    var localizedKey: String {
        switch self {
        case .ascending:
            "library.sort.ascending"
        case .descending:
            "library.sort.descending"
        }
    }
}
