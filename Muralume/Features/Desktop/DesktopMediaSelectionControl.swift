import CoreGraphics
import SwiftUI

struct DesktopMediaSelectionControl: View {
    let items: [LibraryMediaItem]
    let selectedItem: LibraryMediaItem?
    let provider: any MediaThumbnailProviding
    let select: (LibraryMediaItem) -> Void

    @State private var isPickerPresented = false
    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: MuralumeTheme.Spacing.small
        ) {
            Text("desktop.layout.video")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)

            Button {
                isPickerPresented = true
            } label: {
                selectionLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopMediaPicker
            )
            .popover(isPresented: $isPickerPresented, arrowEdge: .trailing) {
                DesktopMediaLibraryPicker(
                    items: items,
                    selectedItemID: selectedItem?.id,
                    provider: provider,
                    select: selectAndDismiss
                )
            }
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            if let selectedItem {
                DesktopMediaThumbnail(
                    item: selectedItem,
                    provider: provider,
                    width: MuralumeTheme.Size.desktopMediaPreviewWidth,
                    height: MuralumeTheme.Size.desktopMediaPreviewHeight
                )
            } else {
                DesktopMediaPlaceholder(
                    width: MuralumeTheme.Size.desktopMediaPreviewWidth,
                    height: MuralumeTheme.Size.desktopMediaPreviewHeight
                )
            }

            Text(verbatim: selectionTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(selectionForegroundStyle)
                .lineLimit(2)

            Spacer(minLength: MuralumeTheme.Spacing.small)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        }
        .padding(MuralumeTheme.Spacing.small)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.canvas.opacity(0.7))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.small,
                    style: .continuous
                )
                .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
        )
    }

    private var selectionTitle: String {
        selectedItem?.displayName
            ?? localization.localized("desktop.layout.chooseLibrary")
    }

    private var selectionForegroundStyle: Color {
        selectedItem == nil
            ? MuralumeTheme.Colors.textSecondary
            : MuralumeTheme.Colors.textPrimary
    }

    private func selectAndDismiss(_ item: LibraryMediaItem) {
        select(item)
        isPickerPresented = false
    }
}

private struct DesktopMediaLibraryPicker: View {
    let items: [LibraryMediaItem]
    let selectedItemID: LibraryMediaItem.ID?
    let provider: any MediaThumbnailProviding
    let select: (LibraryMediaItem) -> Void

    @State private var query = ""

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            TextField("desktop.layout.search", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.desktopMediaSearchField
                )

            ScrollView {
                LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                    ForEach(filteredItems) { item in
                        mediaRow(for: item)
                    }

                    if filteredItems.isEmpty {
                        Text("desktop.layout.noVideo")
                            .font(.callout)
                            .foregroundStyle(
                                MuralumeTheme.Colors.textTertiary
                            )
                            .padding(.vertical, MuralumeTheme.Spacing.xLarge)
                    }
                }
            }
        }
        .padding(MuralumeTheme.Spacing.large)
        .frame(width: 400, height: 360)
    }

    private func mediaRow(for item: LibraryMediaItem) -> some View {
        Button {
            select(item)
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.medium) {
                DesktopMediaThumbnail(
                    item: item,
                    provider: provider,
                    width: MuralumeTheme.Size.playlistArtworkWidth,
                    height: MuralumeTheme.Size.playlistArtworkHeight
                )

                VStack(
                    alignment: .leading,
                    spacing: MuralumeTheme.Spacing.xSmall
                ) {
                    Text(verbatim: item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text(verbatim: item.rootName)
                        .font(.caption)
                        .foregroundStyle(
                            MuralumeTheme.Colors.textSecondary
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: MuralumeTheme.Spacing.small)

                if item.id == selectedItemID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(
                            MuralumeTheme.Colors.accentSecondary
                        )
                }
            }
            .padding(MuralumeTheme.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredItems: [LibraryMediaItem] {
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            return items
        }
        return items.filter {
            $0.displayName.localizedStandardContains(trimmedQuery)
                || $0.rootName.localizedStandardContains(trimmedQuery)
                || $0.relativeDirectory.localizedStandardContains(
                    trimmedQuery
                )
        }
    }
}

private struct DesktopMediaThumbnail: View {
    private struct RequestID: Hashable {
        let itemID: LibraryMediaItem.ID
        let fileSize: Int64
        let modificationDate: Date?
        let width: CGFloat
        let height: CGFloat
        let displayScale: CGFloat
    }

    let item: LibraryMediaItem
    let provider: any MediaThumbnailProviding
    let width: CGFloat
    let height: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(
                    decorative: thumbnail,
                    scale: displayScale,
                    orientation: .up
                )
                .resizable()
                .scaledToFill()
            } else {
                DesktopMediaPlaceholder(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .background(MuralumeTheme.Colors.canvas)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
        )
        .task(id: requestID) {
            thumbnail = nil
            let image = await provider.thumbnail(
                for: item,
                size: CGSize(width: width, height: height),
                scale: displayScale
            )
            guard !Task.isCancelled else {
                return
            }
            thumbnail = image
        }
        .onDisappear {
            thumbnail = nil
        }
        .accessibilityHidden(true)
    }

    private var requestID: RequestID {
        RequestID(
            itemID: item.id,
            fileSize: item.fileSize,
            modificationDate: item.modificationDate,
            width: width,
            height: height,
            displayScale: displayScale
        )
    }
}

private struct DesktopMediaPlaceholder: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MuralumeTheme.Colors.panelRaised,
                    MuralumeTheme.Colors.canvas
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: MuralumeTheme.Size.iconLarge))
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
        }
        .frame(width: width, height: height)
    }
}
