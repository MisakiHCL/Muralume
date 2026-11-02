import SwiftUI

struct CustomPlaylistMediaRow: View {
    @EnvironmentObject private var localization: AppLocalizationController

    let entry: CustomPlaylistEntry
    let item: LibraryMediaItem?
    let issue: CustomPlaylistMediaIssue?
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void
    let revealInFinder: () -> Void
    let showInformation: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let toggleSelection: () -> Void
    let retry: () -> Void
    var reauthorize: (() -> Void)? = nil
    var layout: MediaBrowserLayout = .list
    var artworkSize = CGSize(
        width: MuralumeTheme.Size.playlistArtworkWidth,
        height: MuralumeTheme.Size.playlistArtworkHeight
    )
    var rowHeight: CGFloat = MuralumeTheme.Size.playlistRowHeight
    let playbackState: LibraryMediaRowPlaybackState

    var body: some View {
        let metadata = MediaBrowserItemMetadata(
            item: item, reference: entry.media, localization: localization
        )
        rowControl(metadata: metadata)
        .contentShape(Rectangle())
        .contextMenu {
            if let displayedIssue, displayedIssue != .resolving {
                if displayedIssue == .authorizationRequired
                    || displayedIssue == .permissionDenied,
                   let reauthorize {
                    Button("playlists.media.reauthorize", action: reauthorize)
                }
                if displayedIssue != .authorizationRequired {
                    Button("playlists.media.retry", action: retry)
                }
                Divider()
            }
            if item != nil {
                Button("videoInfo.menu", action: showInformation)
                Button("library.item.revealInFinder", action: revealInFinder)
            }
            if canMoveUp {
                Button("playlists.moveUp", action: moveUp)
            }
            if canMoveDown {
                Button("playlists.moveDown", action: moveDown)
            }
            Divider()
            Button("playlists.removeVideo", role: .destructive, action: remove)
        }
        .accessibilityLabel(Text(verbatim: metadata.accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text(verbatim: recoveryHint))
        .help(Text(verbatim: metadata.tooltipText(
            status: displayedIssue.map { localization.localized($0.localizedMessageKey) }
        )))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playlistEntryPrefix
                + entry.id.rawValue.uuidString
        )
        .customPlaylistMoveAccessibilityActions(
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: moveUp,
            moveDown: moveDown
        )
        .customPlaylistRecoveryAccessibility(
            issue: displayedIssue,
            retry: retry,
            reauthorize: reauthorize
        )
    }

    @ViewBuilder
    private func rowControl(metadata: MediaBrowserItemMetadata) -> some View {
        if let rowAction {
            Button(action: rowAction) {
                rowLabel(metadata: metadata)
            }
            .buttonStyle(MuralumeMediaItemButtonStyle())
            .disabled(!isSelecting && displayedIssue == .resolving)
        } else {
            rowLabel(metadata: metadata)
        }
    }

    private var rowAction: (() -> Void)? {
        if isSelecting { return toggleSelection }
        if displayedIssue == .authorizationRequired || displayedIssue == .permissionDenied,
           let reauthorize { return reauthorize }
        if item != nil { return play }
        if displayedIssue == .authorizationRequired { return nil }
        return displayedIssue == .resolving ? nil : retry
    }

    private func rowLabel(metadata: MediaBrowserItemMetadata) -> some View {
        MediaBrowserItemLabel(
            item: item, metadata: metadata,
            isCurrent: isCurrent, playbackState: displayedPlaybackState,
            rowHeight: rowHeight, mediaThumbnailProvider: mediaThumbnailProvider,
            layout: layout, artworkSize: artworkSize,
            isSelecting: isSelecting, isSelected: isSelected,
            statusHelp: displayedIssue.map { localization.localized($0.localizedMessageKey) }
        )
    }

    private var displayedPlaybackState: LibraryMediaRowPlaybackState {
        if displayedIssue == .resolving { return .loading }
        if displayedIssue != nil { return .unavailable }
        return playbackState
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelecting {
            values.append(localization.localized(
                isSelected
                    ? "library.selection.selected"
                    : "library.selection.notSelected"
            ))
        }
        if let displayedIssue {
            values.append(localization.localized(displayedIssue.localizedMessageKey))
        } else if !isSelecting || displayedPlaybackState != .available {
            values.append(localization.localized(displayedPlaybackState.accessibilityKey))
        }
        return values.joined(separator: ", ")
    }

    private var displayedIssue: CustomPlaylistMediaIssue? {
        issue ?? (item == nil ? .temporarilyUnavailable : nil)
    }

    private var recoveryHint: String {
        guard let displayedIssue, displayedIssue != .resolving else { return "" }
        if displayedIssue == .authorizationRequired || displayedIssue == .permissionDenied,
           reauthorize != nil {
            return localization.localized("playlists.media.reauthorize.hint")
        }
        return displayedIssue == .authorizationRequired
            ? "" : localization.localized("playlists.media.retry.hint")
    }

}

private extension View {
    @ViewBuilder
    func customPlaylistRecoveryAccessibility(
        issue: CustomPlaylistMediaIssue?,
        retry: @escaping () -> Void,
        reauthorize: (() -> Void)?
    ) -> some View {
        if issue == .authorizationRequired, let reauthorize {
            accessibilityAction(named: Text("playlists.media.reauthorize"), reauthorize)
        } else if issue == .permissionDenied, let reauthorize {
            accessibilityAction(named: Text("playlists.media.reauthorize"), reauthorize)
                .accessibilityAction(named: Text("playlists.media.retry"), retry)
        } else if let issue, issue != .authorizationRequired, issue != .resolving {
            accessibilityAction(named: Text("playlists.media.retry"), retry)
        } else {
            self
        }
    }

    @ViewBuilder
    func customPlaylistMoveAccessibilityActions(
        canMoveUp: Bool,
        canMoveDown: Bool,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void
    ) -> some View {
        if canMoveUp && canMoveDown {
            accessibilityAction(
                named: Text("playlists.moveUp"),
                moveUp
            )
            .accessibilityAction(
                named: Text("playlists.moveDown"),
                moveDown
            )
        } else if canMoveUp {
            accessibilityAction(
                named: Text("playlists.moveUp"),
                moveUp
            )
        } else if canMoveDown {
            accessibilityAction(
                named: Text("playlists.moveDown"),
                moveDown
            )
        } else {
            self
        }
    }

}

private extension CustomPlaylistMediaIssue {
    var localizedMessageKey: String {
        switch self {
        case .authorizationRequired:
            "playlists.media.issue.authorizationRequired"
        case .permissionDenied:
            "playlists.media.issue.permissionDenied"
        case .fileMissing:
            "playlists.media.issue.fileMissing"
        case .unsupportedFormat:
            "playlists.media.issue.unsupportedFormat"
        case .cannotOpen:
            "playlists.media.issue.cannotOpen"
        case .temporarilyUnavailable:
            "playlists.media.issue.temporarilyUnavailable"
        case .resolving:
            "playlists.media.issue.resolving"
        }
    }
}
