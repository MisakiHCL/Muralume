import Combine
import SwiftUI

struct VideoViewport<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let playerSurface: PlayerSurface

    @State private var viewportState: PlayerViewportState
    @State private var temporaryRateToken: PlaybackRateOverrideToken?
    @State private var visibleTemporaryRate: PlaybackRate?
    @State private var temporaryRateIndicatorTask: Task<Void, Never>?

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

            SubtitleOverlay(
                externalSubtitles:
                    playback.mediaSelection.externalSubtitles,
                embeddedSubtitles:
                    playback.mediaSelection.embeddedSubtitles,
                appearance: playback.subtitleAppearance
            )

            if let rate = visibleTemporaryRate {
                VStack {
                    PlayerTemporaryPlaybackRateIndicator(rate: rate)
                    Spacer()
                }
                .padding(.top, MuralumeTheme.Spacing.xLarge)
                .transition(.opacity)
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
        let rate = PlaybackPolicy.temporaryFastForwardRate
        guard let token = playback.beginTemporaryPlaybackRate(rate) else {
            return
        }
        temporaryRateToken = token
        showTemporaryRateIndicator(rate)
    }

    private func handleTemporaryFastForwardPressing(_ isPressing: Bool) {
        if !isPressing {
            endTemporaryFastForward()
        }
    }

    private func endTemporaryFastForward() {
        hideTemporaryRateIndicator()
        guard let temporaryRateToken else {
            return
        }
        self.temporaryRateToken = nil
        playback.endTemporaryPlaybackRate(temporaryRateToken)
    }

    private func showTemporaryRateIndicator(_ rate: PlaybackRate) {
        temporaryRateIndicatorTask?.cancel()
        withAnimation(temporaryRateIndicatorAnimation) {
            visibleTemporaryRate = rate
        }
        temporaryRateIndicatorTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    for: PlaybackPolicy
                        .temporaryFastForwardIndicatorDuration
                )
            } catch {
                return
            }
            withAnimation(temporaryRateIndicatorAnimation) {
                visibleTemporaryRate = nil
            }
            temporaryRateIndicatorTask = nil
        }
    }

    private func hideTemporaryRateIndicator() {
        temporaryRateIndicatorTask?.cancel()
        temporaryRateIndicatorTask = nil
        withAnimation(temporaryRateIndicatorAnimation) {
            visibleTemporaryRate = nil
        }
    }

    private var temporaryRateIndicatorAnimation: Animation {
        .easeInOut(
            duration: MuralumeTheme.Motion.playerChromeTransitionDuration
        )
    }
}

private struct SubtitleOverlay: View {
    @ObservedObject var externalSubtitles: ExternalSubtitleController
    @ObservedObject var embeddedSubtitles: EmbeddedSubtitleController
    @ObservedObject var appearance: SubtitleAppearanceController
    @ScaledMetric(relativeTo: .title3) private var bottomInset: CGFloat = 96
    @ScaledMetric(relativeTo: .title3) private var fontScale: CGFloat = 1

    var body: some View {
        if let cueText, !cueText.isEmpty {
            VStack {
                Spacer(minLength: MuralumeTheme.Spacing.xxLarge)

                Text(verbatim: cueText)
                    .font(subtitleFont)
                    .foregroundStyle(
                        appearance.preferences.textColor.swiftUIColor
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .padding(.horizontal, MuralumeTheme.Spacing.medium)
                    .shadow(
                        color: appearance.preferences.shadowColor.swiftUIColor,
                        radius: MuralumeTheme.Subtitle.shadowRadius,
                        x: MuralumeTheme.Subtitle.shadowOffset.width,
                        y: MuralumeTheme.Subtitle.shadowOffset.height
                    )
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

    private var cueText: String? {
        externalSubtitles.cueText ?? embeddedSubtitles.cueText
    }

    private var subtitleFont: Font {
        let fontSize = CGFloat(appearance.preferences.fontSize) * fontScale
        if let fontFamilyName = appearance.preferences.fontFamilyName {
            return .custom(fontFamilyName, size: fontSize).weight(.semibold)
        }
        return .system(size: fontSize, weight: .semibold)
    }
}

extension SubtitleColorValue {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
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
        .muralumePanel(
            cornerRadius: MuralumeTheme.Radius.large,
            style: .playerOverlay
        )
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
