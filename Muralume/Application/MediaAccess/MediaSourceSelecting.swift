import Foundation

enum MediaSourceSelectionIntent: Equatable, Sendable {
    case addingMedia
    case reauthorizingSources
}

@MainActor
protocol MediaSourceSelecting: AnyObject {
    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL]
}
