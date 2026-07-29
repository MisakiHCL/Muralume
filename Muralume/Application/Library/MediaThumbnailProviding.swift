import CoreGraphics

@MainActor
protocol MediaThumbnailProviding: AnyObject {
    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage?

    func shutdown() async
}
