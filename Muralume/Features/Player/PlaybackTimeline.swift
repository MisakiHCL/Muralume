import SwiftUI

struct PlaybackTimeline: View {
    @ObservedObject var playback: PlaybackCoordinator

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            timeLabel(PlayerFormatting.time(playback.currentTime))

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 1)
            )
            .tint(MuralumeTheme.Colors.controlAccent)
            .disabled(!isEnabled)
            .accessibilityLabel(Text("player.timeline"))
            .accessibilityValue(
                Text(
                    verbatim: "\(PlayerFormatting.time(playback.currentTime)) / \(PlayerFormatting.time(playback.duration))"
                )
            )

            timeLabel(PlayerFormatting.time(playback.duration))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playbackTimeline
        )
    }

    private func timeLabel(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var isEnabled: Bool {
        playback.readiness == .ready && !isTransitioning
    }

    private var isTransitioning: Bool {
        if case .switching = playback.presentation {
            return true
        }
        return false
    }
}
