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
    @Environment(\.locale) private var locale
    @State private var isPlaylistPresented = true
    @State private var isPlayerChromeVisible = true
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
                .padding(.horizontal, MuralumeTheme.Spacing.large)
                .padding(.top, playerTopContentInset)
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
                .padding(.top, playerTopContentInset)
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
            .zIndex(4)

            playerTopBar
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .zIndex(5)
        }
        .frame(
            minWidth: AppConfiguration.minimumWindowWidth,
            minHeight: AppConfiguration.minimumWindowHeight
        )
        .ignoresSafeArea(.container, edges: .top)
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
    }

    private var playerTopContentInset: CGFloat {
        MuralumeTheme.Size.playerTopBarHeight
            + MuralumeTheme.Spacing.large
    }

    private var playerTopBar: some View {
        PlayerTopBar(
            playback: playback,
            isFullScreen: isFullScreen,
            actions: actions
        )
        .offset(
            y: isPlayerChromeVisible
                ? 0
                : -MuralumeTheme.Spacing.xLarge
        )
        .opacity(isPlayerChromeVisible ? 1 : 0)
        .allowsHitTesting(isPlayerChromeVisible)
        .accessibilityHidden(!isPlayerChromeVisible)
        .environment(\.locale, locale)
        .preferredColorScheme(.dark)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(
                    duration: MuralumeTheme.Motion
                        .playerChromeTransitionDuration
                ),
            value: isPlayerChromeVisible
        )
    }

    private var shouldAutoHidePlayerChrome: Bool {
        guard playback.readiness == .ready else {
            return false
        }
        guard playback.isActuallyPlaying, !isPlaylistPresented else {
            return false
        }
        return true
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
