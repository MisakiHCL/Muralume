import Combine
import SwiftUI

struct VideoViewport<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let playerSurface: PlayerSurface

    @State private var viewportState: PlayerViewportState
    @State private var temporaryRateToken: PlaybackRateOverrideToken?

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        playerSurface: PlayerSurface
    ) {
        self.playback = playback
        self.library = library
        self.playerSurface = playerSurface
        _viewportState = State(
            initialValue: PlayerViewportState(playback: playback)
        )
    }

    var body: some View {
        ZStack {
            MuralumeTheme.Colors.canvas

            playerSurface
                .accessibilityHidden(true)

            switch viewportState.readiness {
            case .empty:
                PlayerEmptyState(
                    library: library
                )
            case .loading:
                if !viewportState.hasPlayableMedia {
                    PlayerLoadingState()
                }
            case let .failed(failure):
                if !viewportState.hasPlayableMedia {
                    PlayerFailureState(
                        failure: failure,
                        library: library
                    )
                }
            case .ready:
                EmptyView()
            }

            ExternalSubtitleOverlay(
                controller: playback.mediaSelection.externalSubtitles
            )

            if let rate = viewportState.temporaryPlaybackRate {
                PlayerTemporaryPlaybackRateIndicator(rate: rate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: MuralumeTheme.Size.videoMinimumHeight)
        .background(MuralumeTheme.Colors.canvas)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.videoViewport
        )
        .onReceive(viewportStatePublisher) { state in
            viewportState = state
        }
        .onLongPressGesture(
            minimumDuration:
                PlaybackPolicy.temporaryFastForwardPressDuration,
            maximumDistance:
                PlaybackPolicy.temporaryFastForwardMaximumMovement,
            perform: beginTemporaryFastForward,
            onPressingChanged: handleTemporaryFastForwardPressing
        )
        .onDisappear {
            endTemporaryFastForward()
        }
    }

    private var viewportStatePublisher:
        AnyPublisher<PlayerViewportState, Never> {
        Publishers.CombineLatest3(
            playback.$readiness,
            playback.$hasPlayableMedia,
            playback.$temporaryPlaybackRate
        )
        .map { readiness, hasPlayableMedia, temporaryPlaybackRate in
            PlayerViewportState(
                readiness: readiness,
                hasPlayableMedia: hasPlayableMedia,
                temporaryPlaybackRate: temporaryPlaybackRate
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private func beginTemporaryFastForward() {
        temporaryRateToken = playback.beginTemporaryPlaybackRate(
            PlaybackPolicy.temporaryFastForwardRate
        )
    }

    private func handleTemporaryFastForwardPressing(_ isPressing: Bool) {
        if !isPressing {
            endTemporaryFastForward()
        }
    }

    private func endTemporaryFastForward() {
        guard let temporaryRateToken else {
            return
        }
        self.temporaryRateToken = nil
        playback.endTemporaryPlaybackRate(temporaryRateToken)
    }
}

private struct ExternalSubtitleOverlay: View {
    @ObservedObject var controller: ExternalSubtitleController
    @ScaledMetric(relativeTo: .title3) private var bottomInset: CGFloat = 96

    var body: some View {
        if let cueText = controller.cueText, !cueText.isEmpty {
            VStack {
                Spacer(minLength: MuralumeTheme.Spacing.xxLarge)

                Text(verbatim: cueText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .padding(.horizontal, MuralumeTheme.Spacing.medium)
                    .padding(.vertical, MuralumeTheme.Spacing.small)
                    .background {
                        RoundedRectangle(
                            cornerRadius: MuralumeTheme.Radius.small,
                            style: .continuous
                        )
                        .fill(.black.opacity(0.72))
                    }
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, MuralumeTheme.Spacing.xxLarge)
                    .padding(.bottom, bottomInset)
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier.externalSubtitle
                    )
            }
            .allowsHitTesting(false)
        }
    }
}

private struct PlayerViewportState: Equatable {
    let readiness: PlaybackReadiness
    let hasPlayableMedia: Bool
    let temporaryPlaybackRate: PlaybackRate?

    @MainActor
    init(playback: PlaybackCoordinator) {
        readiness = playback.readiness
        hasPlayableMedia = playback.hasPlayableMedia
        temporaryPlaybackRate = playback.temporaryPlaybackRate
    }

    init(
        readiness: PlaybackReadiness,
        hasPlayableMedia: Bool,
        temporaryPlaybackRate: PlaybackRate?
    ) {
        self.readiness = readiness
        self.hasPlayableMedia = hasPlayableMedia
        self.temporaryPlaybackRate = temporaryPlaybackRate
    }
}

private struct PlayerTemporaryPlaybackRateIndicator: View {
    let rate: PlaybackRate

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Image(systemName: "forward.fill")
                .font(.system(size: MuralumeTheme.Size.icon))
            Text(verbatim: PlayerFormatting.rate(rate))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .padding(.horizontal, MuralumeTheme.Spacing.large)
        .padding(.vertical, MuralumeTheme.Spacing.medium)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.large)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("player.temporarySpeed"))
        .accessibilityValue(Text(verbatim: PlayerFormatting.rate(rate)))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.temporaryPlaybackRate
        )
    }
}

private struct PlayerEmptyState: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ScaledMetric(relativeTo: .body) private var messageMinimumHeight =
        MuralumeTheme.Size.emptyMessageMinimumHeight

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            MuralumeBrandMark(size: MuralumeTheme.Size.emptyBrandMark)
                .shadow(
                    color: MuralumeTheme.Colors.accent.opacity(0.3),
                    radius: MuralumeTheme.Shadow.glowRadius
                )

            VStack(spacing: MuralumeTheme.Spacing.small) {
                Text(LocalizedStringKey(titleKey))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MuralumeTheme.Colors.textPrimary)

                Text(LocalizedStringKey(detailKey))
                    .font(.body)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .frame(minHeight: messageMinimumHeight)
        }
        .overlay(alignment: .bottom) {
            if library.scanState == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .accessibilityLabel(Text("library.scanning"))
                    .offset(y: MuralumeTheme.Spacing.xLarge)
            }
        }
        .padding(MuralumeTheme.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuralumeTheme.Colors.canvas)
    }

    private var titleKey: String {
        if library.scanState == .scanning {
            return "library.scanning"
        }
        switch library.sourceAccessState {
        case .temporarilyUnavailable:
            return "library.sourceAccess.unavailable.title"
        case .partiallyUnavailable:
            return "library.sourceAccess.partial"
        case .empty, .available:
            break
        }
        if library.roots.isEmpty {
            return "media.none.title"
        }
        if library.items.isEmpty {
            return "library.empty.title"
        }
        return "media.select.title"
    }

    private var detailKey: String {
        if library.scanState == .scanning {
            return "library.scanning.detail"
        }
        switch library.sourceAccessState {
        case .temporarilyUnavailable:
            return "library.sourceAccess.unavailable.detail"
        case .partiallyUnavailable:
            return "library.sourceAccess.partial.detail"
        case .empty, .available:
            break
        }
        if library.roots.isEmpty {
            return "media.none.detail"
        }
        if library.items.isEmpty {
            return "library.empty.detail"
        }
        return "media.select.detail"
    }
}

private struct PlayerLoadingState: View {
    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            ProgressView()
                .controlSize(.large)
                .tint(MuralumeTheme.Colors.controlAccent)

            Text("player.loading")
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        }
        .padding(MuralumeTheme.Spacing.xLarge)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuralumeTheme.Colors.canvas)
    }
}

private struct PlayerFailureState: View {
    let failure: PlaybackFailure
    @ObservedObject var library: MediaLibraryCoordinator

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.warning)

            Text(LocalizedStringKey(failure.localizedKey))
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            if !library.items.isEmpty {
                Label(
                    "media.error.choose.from.playlist",
                    systemImage: "rectangle.stack.fill"
                )
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            } else {
                Text("library.empty.detail")
                    .font(.body)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(MuralumeTheme.Spacing.xLarge)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuralumeTheme.Colors.canvas)
    }
}

struct PlayerStatusBanner: View {
    private let message: Text
    let dismiss: () -> Void

    init(messageKey: String, dismiss: @escaping () -> Void) {
        message = Text(LocalizedStringKey(messageKey))
        self.dismiss = dismiss
    }

    init(message: String, dismiss: @escaping () -> Void) {
        self.message = Text(verbatim: message)
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MuralumeTheme.Colors.error)

            message
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)

            Spacer(minLength: MuralumeTheme.Spacing.large)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(
                MuralumeControlButtonStyle(scale: .compact)
            )
            .help(Text("action.dismiss"))
            .accessibilityLabel(Text("action.dismiss"))
        }
        .padding(.leading, MuralumeTheme.Spacing.large)
        .padding(.trailing, MuralumeTheme.Spacing.medium)
        .frame(minHeight: 48)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.medium)
    }
}
