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

    var hasIdentifiedLanguage: Bool {
        guard let primaryLanguageSubtag = languageIdentifier?
            .split(separator: "-", maxSplits: 1)
            .first else {
            return false
        }
        return primaryLanguageSubtag.lowercased() != "und"
    }
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
        showsAudioSection || !subtitleOptions.isEmpty
    }

    var showsSubtitleOffControl: Bool {
        !subtitleOptions.isEmpty && allowsEmptySubtitleSelection
    }

    var showsAudioSelectionControls: Bool {
        audioOptions.count > 1
    }

    var singleIdentifiedAudioOption: PlaybackMediaOption? {
        guard audioOptions.count == 1,
              let option = audioOptions.first,
              option.hasIdentifiedLanguage else {
            return nil
        }
        return option
    }

    var showsAudioSection: Bool {
        showsAudioSelectionControls || singleIdentifiedAudioOption != nil
    }
}
