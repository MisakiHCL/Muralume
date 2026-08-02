import Foundation

struct PlayerActions {
    let addVideos: () -> Void
    let addFolders: () -> Void
    let importDroppedURLs: ([URL]) -> Bool
    let enterDesktop: () -> Void
    let toggleSettings: () -> Void
    let closeWindow: () -> Void
    let minimizeWindow: () -> Void
    let toggleFullScreen: () -> Void
}
