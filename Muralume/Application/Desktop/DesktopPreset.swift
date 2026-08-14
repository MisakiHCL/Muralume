import Foundation

struct DesktopPreset: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    private static let mediaLibraryOnlySchemaVersion = 1

    let schemaVersion: Int
    let queue: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    let currentTime: TimeInterval
    let isPlaybackRequested: Bool
    let playbackRateValue: Float
    let videoContentMode: DesktopVideoContentMode
    let playbackCollection: PlaybackCollection
    let queueMediaReferences: [MediaReference]

    init(
        queue: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        currentTime: TimeInterval,
        isPlaybackRequested: Bool,
        playbackRate: PlaybackRate,
        videoContentMode: DesktopVideoContentMode,
        playbackCollection: PlaybackCollection = .mediaLibrary,
        queueMediaReferences: [MediaReference] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.queue = queue
        self.currentTime = currentTime
        self.isPlaybackRequested = isPlaybackRequested
        playbackRateValue = playbackRate.rawValue
        self.videoContentMode = videoContentMode
        self.playbackCollection = playbackCollection
        self.queueMediaReferences = queueMediaReferences
    }

    var playbackRate: PlaybackRate? {
        guard playbackRateValue.isFinite else {
            return nil
        }
        let rate = PlaybackRate(rawValue: playbackRateValue)
        return PlaybackPolicy.supportedRates.contains(rate)
            && rate.rawValue == playbackRateValue
            ? rate
            : nil
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && currentTime.isFinite
            && currentTime >= 0
            && playbackRate != nil
            && queue.isWithinPersistenceLimits
            && hasValidQueueMediaReferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case queue
        case currentTime
        case isPlaybackRequested
        case playbackRateValue
        case videoContentMode
        case playbackCollection
        case queueMediaReferences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        if persistedSchemaVersion == Self.mediaLibraryOnlySchemaVersion {
            schemaVersion = Self.currentSchemaVersion
        } else {
            schemaVersion = persistedSchemaVersion
        }
        queue = try container.decode(
            PlaybackQueueSnapshot<LibraryMediaItem.ID>.self,
            forKey: .queue
        )
        currentTime = try container.decode(
            TimeInterval.self,
            forKey: .currentTime
        )
        isPlaybackRequested = try container.decode(
            Bool.self,
            forKey: .isPlaybackRequested
        )
        playbackRateValue = try container.decode(
            Float.self,
            forKey: .playbackRateValue
        )
        videoContentMode = try container.decode(
            DesktopVideoContentMode.self,
            forKey: .videoContentMode
        )
        if persistedSchemaVersion == Self.mediaLibraryOnlySchemaVersion {
            playbackCollection = .mediaLibrary
            queueMediaReferences = []
        } else {
            playbackCollection = try container.decode(
                PlaybackCollection.self,
                forKey: .playbackCollection
            )
            queueMediaReferences = try container.decode(
                [MediaReference].self,
                forKey: .queueMediaReferences
            )
        }
    }

    private var hasValidQueueMediaReferences: Bool {
        guard queueMediaReferences.count <= queue.items.count else {
            return false
        }
        let queueItemIDs = Set(queue.items)
        var referenceItemIDs: Set<LibraryMediaItem.ID> = []
        for reference in queueMediaReferences {
            guard reference.isValid,
                  queueItemIDs.contains(reference.mediaItemID),
                  referenceItemIDs.insert(
                    reference.mediaItemID
                  ).inserted else {
                return false
            }
        }
        return true
    }
}

enum DesktopPresetStoreError: Error, Equatable, Sendable {
    case invalidPreset
    case fileTooLarge(maximumByteCount: Int, observedByteCount: Int)
    case queueLimitExceeded(
        itemCount: Int,
        historyEntryCount: Int
    )
}

protocol DesktopPresetStoring: Sendable {
    func load() async throws -> DesktopPreset?
    func save(_ preset: DesktopPreset) async throws
    func clear() async throws
}
