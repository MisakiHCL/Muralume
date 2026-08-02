import Foundation

@MainActor
protocol MediaSourceSelecting: AnyObject {
    func selectVideos() -> [URL]
    func selectFolders() -> [URL]
}

extension MediaSourceSelecting {
    func selectVideos() -> [URL] {
        []
    }
}

@available(*, deprecated, renamed: "MediaSourceSelecting")
typealias MediaFolderSelecting = MediaSourceSelecting
