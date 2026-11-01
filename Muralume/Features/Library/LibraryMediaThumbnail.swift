import CoreGraphics
import SwiftUI

struct LibraryMediaThumbnail: View {
    private struct RequestID: Hashable {
        let itemID: LibraryMediaItem.ID
        let fileIdentity: MediaFileIdentity?
        let fileSize: Int64
        let modificationDate: Date?
        let displayScale: CGFloat
        let width: CGFloat
        let height: CGFloat
        let providerID: ObjectIdentifier
    }

    private struct LoadedThumbnail {
        let requestID: RequestID
        let image: CGImage
    }

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: LoadedThumbnail?

    let item: LibraryMediaItem
    let isCurrent: Bool
    let provider: any MediaThumbnailProviding
    var size = CGSize(
        width: MuralumeTheme.Size.playlistArtworkWidth,
        height: MuralumeTheme.Size.playlistArtworkHeight
    )

    var body: some View {
        let requestID = requestID
        let image = thumbnail.flatMap { $0.requestID == requestID ? $0.image : nil }
            ?? provider.cachedThumbnail(for: item, size: size, scale: displayScale)
        Group {
            if let image {
                Image(
                    decorative: image,
                    scale: displayScale,
                    orientation: .up
                )
                .resizable()
                .scaledToFill()
                .background(MuralumeTheme.Colors.canvas)
            } else {
                placeholder
            }
        }
        .frame(
            width: size.width,
            height: size.height
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
        )
        .task(id: requestID) {
            if thumbnail?.requestID != requestID { thumbnail = nil }
            if let image = provider.cachedThumbnail(for: item, size: size, scale: displayScale) {
                thumbnail = LoadedThumbnail(requestID: requestID, image: image)
                return
            }
            let image = await provider.thumbnail(
                for: item,
                size: size,
                scale: displayScale
            )
            guard !Task.isCancelled else {
                return
            }
            thumbnail = image.map { LoadedThumbnail(requestID: requestID, image: $0) }
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
            fileIdentity: item.fileIdentity,
            fileSize: item.fileSize,
            modificationDate: item.modificationDate,
            displayScale: displayScale,
            width: size.width,
            height: size.height,
            providerID: ObjectIdentifier(provider)
        )
    }
}
