import SwiftUI

struct VideoViewport<PlayerSurface: View>: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var library: MediaLibraryCoordinator
    let playerSurface: PlayerSurface

    var body: some View {
        ZStack {
            MuralumeTheme.Colors.canvas

            playerSurface
                .accessibilityHidden(true)

            switch playback.readiness {
            case .empty:
                PlayerEmptyState(
                    library: library
                )
            case .loading:
                PlayerLoadingState()
            case let .failed(failure):
                PlayerFailureState(
                    failure: failure,
                    hasPlaylistItems: !library.items.isEmpty
                )
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
    let hasPlaylistItems: Bool

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.warning)

            Text(LocalizedStringKey(failure.localizedKey))
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            if hasPlaylistItems {
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
