import Foundation

enum MediaSourceSelectionIntent: Equatable, Sendable {
    case addingMedia
    case addingPlaylistVideos
    case reauthorizingSources
    case reauthorizingSource(UnavailableMediaSource)
}

@MainActor
protocol MediaSourceSelecting: AnyObject {
    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL]
}
