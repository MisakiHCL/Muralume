import Foundation

struct DesktopPreset: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let queue: PlaybackQueueSnapshot<LibraryMediaItem.ID>
    let currentTime: TimeInterval
    let isPlaybackRequested: Bool
    let playbackRateValue: Float
    let videoContentMode: DesktopVideoContentMode

    init(
        queue: PlaybackQueueSnapshot<LibraryMediaItem.ID>,
        currentTime: TimeInterval,
        isPlaybackRequested: Bool,
        playbackRate: PlaybackRate,
        videoContentMode: DesktopVideoContentMode
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.queue = queue
        self.currentTime = currentTime
        self.isPlaybackRequested = isPlaybackRequested
        playbackRateValue = playbackRate.rawValue
        self.videoContentMode = videoContentMode
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
