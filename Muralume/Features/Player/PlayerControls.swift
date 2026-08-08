import SwiftUI

struct PlayerControls: View {
    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let actions: PlayerActions
    let isFullScreen: Bool
    let isPlaylistPresented: Bool
    let togglePlaylist: () -> Void

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            PlaybackTimeline(playback: playback)
                .frame(maxWidth: .infinity)

            PlayerSystemSuspensionStatus(playback: playback)

            PlayerControlBar(
                playback: playback,
                library: library,
                actions: actions,
                isFullScreen: isFullScreen,
                isPlaylistPresented: isPlaylistPresented,
                togglePlaylist: togglePlaylist
            )
            .frame(maxWidth: .infinity)
        }
        .padding(MuralumeTheme.Spacing.large)
        .muralumePanel(style: .playerOverlay)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playerControls
        )
    }
}

private struct PlayerSystemSuspensionStatus: View {
    @ObservedObject var playback: PlaybackCoordinator

    var body: some View {
        if playback.isSystemSuspended {
            Label("status.paused.system", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
