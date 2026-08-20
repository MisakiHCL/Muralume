import Foundation

struct PlayerActions {
    let addMedia: () -> Void
    let loadExternalSubtitle: () -> Void
    let retryUnavailableSourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void
    let importDroppedURLs: ([URL]) -> Bool
    let addTemporaryItemsToLibrary: () -> Void
    let restoreDynamicDesktop: () -> Void
    let playLibraryItem: (LibraryMediaItem) -> Void
    let playCustomPlaylistItem:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let addLibraryItemToPlaylist:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let revealMediaInFinder: (URL) -> Void
    let enterDesktop: () -> Void
    let enterDesktopSynchronized: () -> Void
    let presentDesktopLayout: () -> Void
    let cancelDesktopLayout: () -> Void
    let applyDesktopLayout: () -> Void
    let toggleSettings: () -> Void
    let closeWindow: () -> Void
    let minimizeWindow: () -> Void
    let toggleFullScreen: () -> Void
}
