import Foundation

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

    private var unmutedVolume: PlaybackVolume

    init(
        volume: PlaybackVolume,
        isMuted: Bool,
        rate: PlaybackRate
    ) {
        self.volume = isMuted ? .muted : volume
        self.isMuted = isMuted
        self.rate = rate
        unmutedVolume = volume
    }

    mutating func setVolume(_ volume: PlaybackVolume) {
        guard volume != .muted else {
            if !isMuted {
                self.volume = .muted
            }
            return
        }

        self.volume = volume
        unmutedVolume = volume
        isMuted = false
    }

    mutating func setMuted(_ isMuted: Bool) {
        guard self.isMuted != isMuted else {
            return
        }

        if isMuted {
            if volume != .muted {
                unmutedVolume = volume
            }
            volume = .muted
        } else {
            volume = unmutedVolume
        }
        self.isMuted = isMuted
    }
}

enum PlaybackIntent: Equatable, Sendable {
    case playing
    case paused
}

enum PlaybackSuspensionReason: Hashable, Sendable {
    case screenLocked
    case displaySleeping
    case systemSleeping
    case sessionInactive
    case thermalPressure
}
