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

struct LibraryBrowserLayoutPicker: View {
    @Binding var layout: MediaBrowserLayout

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.libraryBrowserControls) {
            layoutButton(.list, icon: "list.bullet")
            layoutButton(.grid, icon: "square.grid.2x2")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("library.layout"))
        .accessibilityIdentifier(MuralumeAccessibilityIdentifier.libraryLayoutPicker)
    }

    private func layoutButton(_ value: MediaBrowserLayout, icon: String) -> some View {
        let title = LocalizedStringKey(value == .grid ? "library.layout.grid" : "library.layout.list")
        return Button { layout = value } label: {
            Image(systemName: icon)
        }
        .buttonStyle(LibraryBrowserControlStyle(isSelected: layout == value))
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(layout == value ? .isSelected : [])
        .accessibilityIdentifier(value == .grid
            ? MuralumeAccessibilityIdentifier.libraryGridButton
            : MuralumeAccessibilityIdentifier.libraryListButton)
    }
}

struct MediaBrowserSelectionControl: View {
    let isSelecting: Bool
    let isEnabled: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
        let title = LocalizedStringKey(isSelecting
            ? "library.selection.done" : "library.selection.begin")
        Button(action: toggle) {
            Image(systemName: "checkmark.circle")
        }
        .buttonStyle(LibraryBrowserControlStyle(isSelected: isSelecting))
        .disabled(!isEnabled)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelecting ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

struct MediaBrowserSelectionActionsMenu: View {
    let canSelectAll: Bool
    let canClear: Bool
    let identifier: String
    let selectAllIdentifier: String
    let clearIdentifier: String
    let selectAll: () -> Void
    let clear: () -> Void

    var body: some View {
        Menu {
            Button("library.selection.all", action: selectAll)
                .disabled(!canSelectAll)
                .accessibilityIdentifier(selectAllIdentifier)
            Button("library.selection.clear", action: clear)
                .disabled(!canClear)
                .accessibilityIdentifier(clearIdentifier)
        } label: {
            Image(systemName: "checklist")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("library.selection.actions"))
        .accessibilityIdentifier(identifier)
    }
}

/// Keeps the icon, highlight and hit area consistent for buttons and menus.
struct LibraryBrowserControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: MuralumeTheme.Size.libraryBrowserControlIconSize))
            .foregroundStyle(isSelected
                ? MuralumeTheme.Colors.textPrimary : MuralumeTheme.Colors.textSecondary)
            .frame(
                width: MuralumeTheme.Size.libraryBrowserControlSize,
                height: MuralumeTheme.Size.libraryBrowserControlSize
            )
            .background {
                if isSelected || configuration.isPressed {
                    RoundedRectangle(cornerRadius: MuralumeTheme.Radius.small)
                        .fill(MuralumeTheme.Colors.controlHover)
                        .overlay {
                            if colorSchemeContrast == .increased {
                                RoundedRectangle(cornerRadius: MuralumeTheme.Radius.small)
                                    .strokeBorder(MuralumeTheme.Colors.textSecondary, lineWidth: 1)
                            }
                        }
                        .frame(
                            width: MuralumeTheme.Size.libraryBrowserControlHighlightSize,
                            height: MuralumeTheme.Size.libraryBrowserControlHighlightSize
                        )
                }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.34)
    }
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
