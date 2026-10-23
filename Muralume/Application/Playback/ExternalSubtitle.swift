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
    private let endTimeTree: [TimeInterval]
    private let leafOffset: Int

    init(cues: [SubtitleCue]) {
        self.cues = cues.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        var offset = 1
        while offset < cues.count { offset *= 2 }
        leafOffset = offset
        var tree = [TimeInterval](repeating: 0, count: offset * 2)
        for (index, cue) in self.cues.enumerated() {
            tree[offset + index] = cue.endTime
        }
        if offset > 1 {
            for index in stride(from: offset - 1, through: 1, by: -1) {
                tree[index] = max(tree[index * 2], tree[index * 2 + 1])
            }
        }
        endTimeTree = tree
    }

    func text(at time: TimeInterval) -> String? {
        query(at: time).text
    }

    fileprivate func query(
        at time: TimeInterval
    ) -> (text: String?, validUntil: TimeInterval) {
        guard time.isFinite, time >= 0, !cues.isEmpty else {
            return (nil, time)
        }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].startTime <= time { lower = middle + 1 }
            else { upper = middle }
        }
        var validUntil = lower < cues.count
            ? cues[lower].startTime : TimeInterval.infinity
        var texts: [String] = []
        func collect(node: Int, start: Int, end: Int) {
            guard start < lower, endTimeTree[node] > time else { return }
            if end - start == 1 {
                let cue = cues[start]
                texts.append(cue.text)
                validUntil = min(validUntil, cue.endTime)
                return
            }
            let middle = (start + end) / 2
            collect(node: node * 2, start: start, end: middle)
            collect(node: node * 2 + 1, start: middle, end: end)
        }
        collect(node: 1, start: 0, end: leafOffset)
        return (texts.isEmpty ? nil : texts.joined(separator: "\n"), validUntil)
    }
}

/// Session-owned query state. Reuses the composed text until the next cue
/// boundary, while backwards seeks rebuild directly from the interval index.
struct SubtitleTimelineCursor {
    private let timeline: SubtitleTimeline
    private var lastTime: TimeInterval = -.infinity
    private var validUntil: TimeInterval = -.infinity
    private var cachedText: String?
    private(set) var queryCount = 0

    init(timeline: SubtitleTimeline) {
        self.timeline = timeline
    }

    mutating func text(at time: TimeInterval) -> String? {
        guard time.isFinite, time >= 0 else { return nil }
        if time >= lastTime, time < validUntil {
            lastTime = time
            return cachedText
        }
        let result = timeline.query(at: time)
        queryCount += 1
        lastTime = time
        validUntil = result.validUntil
        cachedText = result.text
        return cachedText
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
