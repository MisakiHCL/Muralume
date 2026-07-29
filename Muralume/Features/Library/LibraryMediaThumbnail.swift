import CoreGraphics
import SwiftUI

struct LibraryMediaThumbnail: View {
    private struct RequestID: Hashable {
        let itemID: LibraryMediaItem.ID
        let fileSize: Int64
        let modificationDate: Date?
        let displayScale: CGFloat
    }

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    let item: LibraryMediaItem
    let isCurrent: Bool
    let provider: any MediaThumbnailProviding

    var body: some View {
        ZStack {
            placeholder

            if let thumbnail {
                Image(
                    decorative: thumbnail,
                    scale: displayScale,
                    orientation: .up
                )
                .resizable()
                .scaledToFill()
            }
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
        .task(id: requestID) {
            thumbnail = nil
            let image = await provider.thumbnail(
                for: item,
                size: CGSize(
                    width: MuralumeTheme.Size.playlistArtworkWidth,
                    height: MuralumeTheme.Size.playlistArtworkHeight
                ),
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

    private var placeholder: some View {
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
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(
                    isCurrent
                        ? MuralumeTheme.Colors.controlAccent
                        : MuralumeTheme.Colors.textTertiary
                )
        }
    }

    private var requestID: RequestID {
        RequestID(
            itemID: item.id,
            fileSize: item.fileSize,
            modificationDate: item.modificationDate,
            displayScale: displayScale
        )
    }
}
