import SwiftUI

/// The library and curated playlists share sizing, virtualization and scrolling.
/// Their item identities, available actions and playback collections remain distinct.
struct MediaCollectionBrowser<Item: Identifiable, RowContent: View>: View
    where Item.ID: Hashable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let items: [Item]
    let layout: MediaBrowserLayout
    let snapshotRevision: AnyHashable
    let rowContentRevision: AnyHashable
    let scrollTargetID: Item.ID?
    let scrollToTopRequest: UInt64?
    let rowHeight: CGFloat
    @ViewBuilder let rowContent: (Item, MediaBrowserLayout, CGSize) -> RowContent

    var body: some View {
        if layout == .grid {
            GeometryReader { geometry in
                let size = MediaBrowserGridMetrics.itemSize(
                    availableWidth: geometry.size.width,
                    accessibilitySize: dynamicTypeSize.isAccessibilitySize
                )
                FixedSizeVirtualizedGrid(
                    items: items,
                    snapshotRevision: snapshotRevision,
                    rowContentRevision: rowContentRevision,
                    scrollTargetID: scrollTargetID,
                    scrollToTopRequest: scrollToTopRequest,
                    itemSize: size,
                    spacing: MuralumeTheme.Spacing.xSmall
                ) { item in
                    rowContent(item, .grid, size)
                }
            }
            .padding(.top, MuralumeTheme.Size.playlistContentInset)
        } else {
            FixedHeightVirtualizedTable(
                items: items,
                snapshotRevision: snapshotRevision,
                rowContentRevision: rowContentRevision,
                scrollTargetID: scrollTargetID,
                scrollToTopRequest: scrollToTopRequest,
                rowHeight: rowHeight,
                rowSpacing: MuralumeTheme.Spacing.xSmall,
                verticalContentInset: MuralumeTheme.Size.playlistContentInset
            ) { item in
                rowContent(
                    item, .list,
                    MuralumeTheme.Size.mediaItemListArtworkSize(rowHeight: rowHeight)
                )
            }
        }
    }
}

enum MediaBrowserGridMetrics {
    static func itemSize(
        availableWidth: CGFloat,
        accessibilitySize: Bool
    ) -> CGSize {
        let spacing = MuralumeTheme.Spacing.xSmall
        let availableWidth = availableWidth.isFinite ? availableWidth : 0
        let usableWidth = max(availableWidth - MuralumeTheme.Size.libraryGridScrollerAllowance, 0)
        let columns = accessibilitySize ? 1 : max(
            Int((usableWidth + spacing) / (MuralumeTheme.Size.libraryGridMinimumWidth + spacing)), 1
        )
        let width = max(floor((usableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns) / 4) * 4, 4)
        return CGSize(width: width, height: width)
    }
}
