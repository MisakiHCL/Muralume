import CoreGraphics

@MainActor
protocol MediaThumbnailProviding: AnyObject {
    /// Reads an already generated in-memory image without starting media work.
    func cachedThumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage?

    /// Reuses a valid in-memory representation while a different size is loading.
    /// This does not start work or satisfy the exact-size thumbnail request.
    func cachedPreviewThumbnail(for item: LibraryMediaItem) -> CGImage?

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

extension MediaThumbnailProviding {
    func cachedPreviewThumbnail(for item: LibraryMediaItem) -> CGImage? { nil }

    func cachedThumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? { nil }
}
