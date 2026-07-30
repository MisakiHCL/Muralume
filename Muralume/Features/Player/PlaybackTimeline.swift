import Combine
import SwiftUI

struct PlaybackTimeline: View {
    let playback: PlaybackCoordinator
    @State private var timelineState: PlaybackTimelineState

    init(playback: PlaybackCoordinator) {
        self.playback = playback
        _timelineState = State(
            initialValue: PlaybackTimelineState(playback: playback)
        )
    }

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            timeLabel(PlayerFormatting.time(timelineState.currentTime))

            MuralumeSlider(
                value: Binding(
                    get: { timelineState.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(timelineState.duration, 1),
                kind: .timeline,
                onEditingChanged: { isEditing in
                    if isEditing {
                        playback.beginTimelineSeek()
                    } else {
                        playback.endTimelineSeek()
                    }
                }
            )
            .frame(height: MuralumeTheme.Size.sliderHitTargetHeight)
            .disabled(!isEnabled)
            .accessibilityLabel(Text("player.timeline"))
            .accessibilityValue(
                Text(
                    verbatim: "\(PlayerFormatting.time(timelineState.currentTime)) / \(PlayerFormatting.time(timelineState.duration))"
                )
            )

            timeLabel(PlayerFormatting.time(timelineState.duration))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playbackTimeline
        )
        .onReceive(timelineStatePublisher) { state in
            timelineState = state
        }
    }

    private func timeLabel(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private var isEnabled: Bool {
        timelineState.readiness == .ready && !isTransitioning
    }

    private var isTransitioning: Bool {
        if case .switching = timelineState.presentation {
            return true
        }
        return false
    }

    private var timelineStatePublisher:
        AnyPublisher<PlaybackTimelineState, Never> {
        Publishers.CombineLatest4(
            playback.$currentTime,
            playback.$duration,
            playback.$readiness,
            playback.$presentation
        )
        .map {
            PlaybackTimelineState(
                currentTime: $0,
                duration: $1,
                readiness: $2,
                presentation: $3
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}

private struct PlaybackTimelineState: Equatable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let readiness: PlaybackReadiness
    let presentation: PlaybackPresentation

    @MainActor
    init(playback: PlaybackCoordinator) {
        currentTime = playback.currentTime
        duration = playback.duration
        readiness = playback.readiness
        presentation = playback.presentation
    }

    init(
        currentTime: TimeInterval,
        duration: TimeInterval,
        readiness: PlaybackReadiness,
        presentation: PlaybackPresentation
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.readiness = readiness
        self.presentation = presentation
    }
}
