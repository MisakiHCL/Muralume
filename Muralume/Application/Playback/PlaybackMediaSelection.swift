import Foundation

struct PlaybackMediaOptionID: Equatable, Hashable, Sendable {
    let rawValue: String
}

enum PlaybackMediaOptionCharacteristic: Equatable, Hashable, Sendable {
    case audioDescription
    case dubbedTranslation
    case forcedSubtitles
    case closedCaptions
}

struct PlaybackMediaOption: Equatable, Identifiable, Sendable {
    let id: PlaybackMediaOptionID
    let displayName: String
    let languageIdentifier: String?
    let characteristics: Set<PlaybackMediaOptionCharacteristic>
}

enum PlaybackAudioSelection: Equatable, Sendable {
    case automatic
    case option(PlaybackMediaOptionID)
}

enum PlaybackSubtitleSelection: Equatable, Sendable {
    case automatic
    case off
    case option(PlaybackMediaOptionID)
}

struct PlaybackMediaSelectionState: Equatable, Sendable {
    static let empty = PlaybackMediaSelectionState(
        audioOptions: [],
        subtitleOptions: [],
        audioSelection: .automatic,
        subtitleSelection: .automatic,
        effectiveAudioOptionID: nil,
        effectiveSubtitleOptionID: nil,
        allowsEmptySubtitleSelection: true
    )

    let audioOptions: [PlaybackMediaOption]
    let subtitleOptions: [PlaybackMediaOption]
    let audioSelection: PlaybackAudioSelection
    let subtitleSelection: PlaybackSubtitleSelection
    let effectiveAudioOptionID: PlaybackMediaOptionID?
    let effectiveSubtitleOptionID: PlaybackMediaOptionID?
    let allowsEmptySubtitleSelection: Bool

    var showsTrackControls: Bool {
        audioOptions.count > 1 || !subtitleOptions.isEmpty
    }
}
