import Combine
import SwiftUI

struct VideoViewport<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let playerSurface: PlayerSurface

    @State private var viewportState: PlayerViewportState

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
    }

    private var viewportStatePublisher:
        AnyPublisher<PlayerViewportState, Never> {
        Publishers.CombineLatest(
            playback.$readiness,
            playback.$hasPlayableMedia
        )
        .map { readiness, hasPlayableMedia in
            PlayerViewportState(
                readiness: readiness,
                hasPlayableMedia: hasPlayableMedia
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}

private struct PlayerViewportState: Equatable {
    let readiness: PlaybackReadiness
    let hasPlayableMedia: Bool

    @MainActor
    init(playback: PlaybackCoordinator) {
        readiness = playback.readiness
        hasPlayableMedia = playback.hasPlayableMedia
    }

    init(
        readiness: PlaybackReadiness,
        hasPlayableMedia: Bool
    ) {
        self.readiness = readiness
        self.hasPlayableMedia = hasPlayableMedia
    }
}

private struct PlayerEmptyState: View {
    @ObservedObject var library: MediaLibraryCoordinator

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

            if library.scanState == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .accessibilityLabel(Text("library.scanning"))
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
    let messageKey: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MuralumeTheme.Colors.error)

            Text(LocalizedStringKey(messageKey))
                .font(.body)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)

            Spacer(minLength: MuralumeTheme.Spacing.large)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("action.dismiss"))
            .accessibilityLabel(Text("action.dismiss"))
        }
        .padding(.leading, MuralumeTheme.Spacing.large)
        .padding(.trailing, MuralumeTheme.Spacing.medium)
        .frame(minHeight: 48)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.medium)
    }
}
