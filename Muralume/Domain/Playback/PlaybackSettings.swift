import Foundation

enum PlaybackRepeatBehavior: String, Codable, Hashable, Sendable {
    case queue
    case currentItem
}

/// The three user-facing playback choices. Queue ordering and repeat behavior
/// remain separate internally so repeating one item never mutates navigation.
enum PlaybackMode: String, CaseIterable, Hashable, Sendable {
    case ordered
    case shuffled
    case repeatCurrent

    init(
        order: PlaybackOrder,
        repeatBehavior: PlaybackRepeatBehavior
    ) {
        if repeatBehavior == .currentItem {
            self = .repeatCurrent
        } else {
            self = order == .ordered ? .ordered : .shuffled
        }
    }
}

enum PlaybackItemEndDisposition: Equatable, Sendable {
    case unhandled
    case advanced
    case repeatCurrent
}

struct PlaybackVolume: Equatable, Sendable {
    static let muted = PlaybackVolume(rawValue: 0)
    static let full = PlaybackVolume(rawValue: 1)

    let rawValue: Float

    init(rawValue: Float) {
        self.rawValue = min(max(rawValue, 0), 1)
    }
}

struct PlaybackRate: Equatable, Hashable, Sendable {
    let rawValue: Float

    init(rawValue: Float) {
        self.rawValue = min(max(rawValue, 0.25), 2)
    }
}

struct PlaybackSettings: Equatable, Sendable {
    private(set) var volume: PlaybackVolume
    private(set) var isMuted: Bool
    var rate: PlaybackRate

    private(set) var restorableVolume: PlaybackVolume

    init(
        volume: PlaybackVolume,
        isMuted: Bool,
        rate: PlaybackRate,
        restorableVolume: PlaybackVolume? = nil
    ) {
        self.volume = isMuted ? .muted : volume
        self.isMuted = isMuted
        self.rate = rate
        if !isMuted, volume != .muted {
            self.restorableVolume = volume
        } else if let restorableVolume,
                  restorableVolume != .muted {
            self.restorableVolume = restorableVolume
        } else {
            self.restorableVolume = .full
        }
    }

    mutating func setVolume(_ volume: PlaybackVolume) {
        guard volume != .muted else {
            if !isMuted {
                self.volume = .muted
            }
            return
        }

        self.volume = volume
        restorableVolume = volume
        isMuted = false
    }

    mutating func setMuted(_ isMuted: Bool) {
        guard self.isMuted != isMuted else {
            return
        }

        if isMuted {
            if volume != .muted {
                restorableVolume = volume
            }
            volume = .muted
        } else {
            volume = restorableVolume
        }
        self.isMuted = isMuted
    }
}

enum PlaybackIntent: Equatable, Sendable {
    case playing
    case paused
}

enum PlaybackSuspensionReason: Hashable, Sendable {
    case playerWindowMiniaturized
    case screenLocked
    case displaySleeping
    case systemSleeping
    case sessionInactive
    case thermalPressure
}
