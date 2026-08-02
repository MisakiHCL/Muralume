import CoreGraphics

@MainActor
protocol MediaThumbnailProviding: AnyObject {
    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage?

    func purgeMemoryCache()

    /// Re-enables requests for roots that are currently active. This matters
    /// when a user removes and later re-adds the same folder in one process.
    func allowThumbnails(forRootIDs rootIDs: Set<MediaLibraryRoot.ID>)

    /// Cancels and drains thumbnail work that may still be reading this root.
    /// The caller can release the root's security scope after this returns.
    func invalidateThumbnails(forRootID rootID: MediaLibraryRoot.ID) async

    func shutdown() async
}
