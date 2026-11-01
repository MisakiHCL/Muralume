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

    var body: some View {
        rowControl
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
        .accessibilityLabel(
            Text(verbatim: item?.displayName ?? entry.media.lastKnownDisplayName)
        )
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text(verbatim: recoveryHint))
        .help(Text(verbatim: tooltipText))
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
    private var rowControl: some View {
        if let rowAction {
            Button(action: rowAction) {
                rowLabel
            }
            .buttonStyle(MuralumeMediaItemButtonStyle())
            .disabled(!isSelecting && displayedIssue == .resolving)
        } else {
            rowLabel
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

    private var rowLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected
                            ? MuralumeTheme.Colors.controlAccent
                            : MuralumeTheme.Colors.textTertiary
                    )
                    .frame(width: MuralumeTheme.Size.iconLarge)
                    .accessibilityHidden(true)
            }
            if let item {
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )
            } else {
                unavailableThumbnail
            }

            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.xSmall
            ) {
                Text(
                    verbatim: item?.displayName
                        ?? entry.media.lastKnownDisplayName
                )
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                Text(
                    verbatim: item?.relativePath
                        ?? entry.media.mediaItemID.relativePath
                )
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: MuralumeTheme.Spacing.small)
            if displayedIssue == .resolving {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: MuralumeTheme.Size.iconLarge,
                        height: MuralumeTheme.Size.iconLarge
                    )
                    .help(Text(verbatim: tooltipText))
                    .accessibilityHidden(true)
            } else if displayedIssue != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .help(Text(verbatim: tooltipText))
                    .accessibilityHidden(true)
            } else if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                    .accessibilityHidden(true)
            }
        }
        .padding(MuralumeTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: MuralumeTheme.Size.control * 2)
        .background {
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
        }
        return values.joined(separator: ", ")
    }

    private var displayedIssue: CustomPlaylistMediaIssue? {
        issue ?? (item == nil ? .temporarilyUnavailable : nil)
    }

    private var tooltipText: String {
        if let displayedIssue {
            return localization.localized(displayedIssue.localizedMessageKey)
        }
        return item?.url.path ?? entry.media.mediaItemID.standardizedMediaPath
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

    private var unavailableThumbnail: some View {
        ZStack {
            MuralumeTheme.Colors.panelRaised
            Image(systemName: "film")
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
        }
        .frame(
            width: MuralumeTheme.Size.playlistArtworkWidth,
            height: MuralumeTheme.Size.playlistArtworkHeight
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
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
