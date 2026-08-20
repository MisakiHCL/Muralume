import Foundation

enum ExternalSubtitlePolicy {
    static let supportedExtensions: Set<String> = ["srt", "vtt"]
    static let maximumFileBytes = 4 * 1_024 * 1_024
    static let maximumCueCount = 20_000
    static let maximumCueCharacters = 4_096
    static let maximumDirectoryEntries = 512
    static let maximumStoredAssociations = 64
    static let maximumBookmarkBytes = 64 * 1_024
    static let timeUpdateInterval: TimeInterval = 0.05
}

struct SubtitleCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct SubtitleTimeline: Equatable, Sendable {
    let cues: [SubtitleCue]
    private let maximumEndTimes: [TimeInterval]

    init(cues: [SubtitleCue]) {
        self.cues = cues.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }

        var maximumEndTime: TimeInterval = 0
        maximumEndTimes = self.cues.map { cue in
            maximumEndTime = max(maximumEndTime, cue.endTime)
            return maximumEndTime
        }
    }

    func text(at time: TimeInterval) -> String? {
        guard time.isFinite, time >= 0, !cues.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = cues.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if cues[middle].startTime <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        var index = lowerBound - 1
        var activeTexts: [String] = []
        while index >= 0, maximumEndTimes[index] > time {
            let cue = cues[index]
            if cue.startTime <= time, cue.endTime > time {
                activeTexts.append(cue.text)
            }
            index -= 1
        }

        guard !activeTexts.isEmpty else {
            return nil
        }
        return activeTexts.reversed().joined(separator: "\n")
    }
}

enum ExternalSubtitleLoadFailure: Error, Equatable, Sendable {
    case cannotRead
    case fileTooLarge
    case unsupportedEncoding
    case invalidFormat
    case tooManyCues

    var localizedKey: String {
        switch self {
        case .cannotRead:
            "player.tracks.external.error.cannotRead"
        case .fileTooLarge:
            "player.tracks.external.error.fileTooLarge"
        case .unsupportedEncoding:
            "player.tracks.external.error.encoding"
        case .invalidFormat:
            "player.tracks.external.error.format"
        case .tooManyCues:
            "player.tracks.external.error.tooManyCues"
        }
    }
}

enum ExternalSubtitleOrigin: Equatable, Sendable {
    case discovered
    case remembered
    case userSelected
}

struct ExternalSubtitleTrack: Equatable, Sendable {
    let url: URL
    let displayName: String
    let origin: ExternalSubtitleOrigin
}

protocol SubtitleFileParsing: Sendable {
    func parse(_ url: URL) throws -> SubtitleTimeline
}

protocol ExternalSubtitleDiscovering: Sendable {
    func discover(
        for mediaURL: URL,
        preferredLanguageCodes: [String]
    ) -> URL?
}

@MainActor
protocol ExternalSubtitleAssociationStoring: AnyObject {
    func subtitleURL(for mediaURL: URL) -> URL?
    func save(subtitleURL: URL, for mediaURL: URL)
    func removeSubtitleURL(for mediaURL: URL)
}

@MainActor
protocol ExternalSubtitleSelecting: AnyObject {
    func selectSubtitle() -> URL?
}
