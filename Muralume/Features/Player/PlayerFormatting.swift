import Foundation

enum PlayerFormatting {
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func rate(_ rate: PlaybackRate) -> String {
        String(format: "%g×", rate.rawValue)
    }

    static func volume(_ volume: PlaybackVolume) -> String {
        "\(Int((volume.rawValue * 100).rounded()))%"
    }
}
