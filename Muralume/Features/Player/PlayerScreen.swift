import SwiftUI

struct PlayerScreen<PlayerSurface: View>: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var desktopSession: DesktopSessionCoordinator
    @ObservedObject var library: MediaLibraryCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isFullScreen: Bool
    let actions: PlayerActions
    let playerSurface: PlayerSurface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPlaylistPresented = true
    @State private var isPlayerChromeVisible = true
    @State private var isPointerOverPlayerChrome = false
    @State private var playerChromeActivitySequence = 0
    @State private var restoresPlaylistAfterFullScreen = false

    var body: some View {
        ZStack {
            MuralumeTheme.Colors.canvas

            VideoViewport(
                playback: playback,
                library: library,
                playerSurface: playerSurface
            )

            PointerActivityReader {
                recordPlayerChromeActivity()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(1)

            if let failure = desktopSession.transientFailure {
                PlayerStatusBanner(
                    messageKey: failure.localizedKey,
                    dismiss: {
                        desktopSession.dismissTransientFailure()
                    }
                )
                .frame(maxWidth: 560)
                .padding(MuralumeTheme.Spacing.large)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .zIndex(3)
            }

            if isPlaylistPresented {
                LibraryQueueSidebar(
                    library: library,
                    playback: playback,
                    mediaThumbnailProvider: mediaThumbnailProvider,
                    addFolders: actions.addFolders,
                    dismiss: {
                        setPlaylistPresented(false)
                    }
                )
                .padding(.top, MuralumeTheme.Spacing.large)
                .padding(.trailing, MuralumeTheme.Spacing.large)
                .padding(
                    .bottom,
                    MuralumeTheme.Size.playerControlsReservedHeight
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
                .zIndex(2)
            }

            PlayerControls(
                playback: playback,
                library: library,
                actions: actions,
                isPlaylistPresented: isPlaylistPresented,
                togglePlaylist: {
                    setPlaylistPresented(!isPlaylistPresented)
                }
            )
            .frame(
                maxWidth: MuralumeTheme.Size.playerControlsMaximumWidth
            )
            .padding(MuralumeTheme.Spacing.large)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
            .offset(
                y: isPlayerChromeVisible
                    ? 0
                    : MuralumeTheme.Spacing.xLarge
            )
            .opacity(isPlayerChromeVisible ? 1 : 0)
            .allowsHitTesting(isPlayerChromeVisible)
            .accessibilityHidden(!isPlayerChromeVisible)
            .onHover { isHovering in
                isPointerOverPlayerChrome = isHovering
                if isHovering {
                    recordPlayerChromeActivity()
                } else {
                    restartPlayerChromeAutoHideCountdown()
                }
            }
            .zIndex(4)
        }
        .frame(
            minWidth: AppConfiguration.minimumWindowWidth,
            minHeight: AppConfiguration.minimumWindowHeight
        )
        .onChange(of: playback.isActuallyPlaying) {
            handlePlayerChromePolicyChange()
        }
        .onChange(of: playback.readiness) {
            handlePlayerChromePolicyChange()
        }
        .onChange(of: isFullScreen) {
            handleFullScreenChange()
        }
        .task(id: playerChromeActivitySequence) {
            let activitySequence = playerChromeActivitySequence
            guard shouldAutoHidePlayerChrome else {
                return
            }
            do {
                try await Task.sleep(
                    nanoseconds: MuralumeTheme.Motion
                        .playerChromeAutoHideNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  activitySequence == playerChromeActivitySequence,
                  shouldAutoHidePlayerChrome else {
                return
            }
            setPlayerChromeVisible(false)
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .toolbar {
            PlayerToolbar(playback: playback)
        }
        .toolbarBackground(
            MuralumeTheme.Colors.window,
            for: .windowToolbar
        )
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
    }

    private var shouldAutoHidePlayerChrome: Bool {
        guard playback.readiness == .ready else {
            return false
        }
        guard playback.isActuallyPlaying, !isPlaylistPresented else {
            return false
        }
        return isFullScreen || !isPointerOverPlayerChrome
    }

    private func handleFullScreenChange() {
        if isFullScreen {
            handlePlayerChromePolicyChange()
            return
        }

        if restoresPlaylistAfterFullScreen, !isPlaylistPresented {
            setPlaylistPresented(true)
        } else {
            recordPlayerChromeActivity()
        }
        restoresPlaylistAfterFullScreen = false
    }

    private func handlePlayerChromePolicyChange() {
        if isFullScreen,
           playback.readiness == .ready,
           playback.isActuallyPlaying,
           isPlaylistPresented {
            restoresPlaylistAfterFullScreen = true
            setPlaylistPresented(false)
        } else {
            recordPlayerChromeActivity()
        }
    }

    private func setPlaylistPresented(_ isPresented: Bool) {
        setPlayerChromeVisible(true)
        withPlayerChromeAnimation {
            isPlaylistPresented = isPresented
        }
        playerChromeActivitySequence += 1
    }

    private func recordPlayerChromeActivity() {
        setPlayerChromeVisible(true)
        playerChromeActivitySequence += 1
    }

    private func restartPlayerChromeAutoHideCountdown() {
        guard shouldAutoHidePlayerChrome else {
            return
        }
        playerChromeActivitySequence += 1
    }

    private func setPlayerChromeVisible(_ isVisible: Bool) {
        guard isPlayerChromeVisible != isVisible else {
            return
        }
        withPlayerChromeAnimation {
            isPlayerChromeVisible = isVisible
        }
    }

    private func withPlayerChromeAnimation(
        _ updates: () -> Void
    ) {
        guard !reduceMotion else {
            updates()
            return
        }
        withAnimation(
            .easeOut(
                duration: MuralumeTheme.Motion
                    .playerChromeTransitionDuration
            ),
            updates
        )
    }
}
