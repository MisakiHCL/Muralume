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

    /// Cooperatively cancels thumbnail work and waits for it up to the
    /// provider's bounded drain deadline. After this returns, late system
    /// completions cannot publish or cache results for the invalidated root, so
    /// the caller can release the root's security scope.
    func invalidateThumbnails(forRootID rootID: MediaLibraryRoot.ID) async

    func shutdown() async
}
