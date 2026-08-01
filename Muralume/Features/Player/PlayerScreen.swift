import Combine
import SwiftUI

struct PlayerScreen<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    @ObservedObject var desktopSession: DesktopSessionCoordinator
    let library: MediaLibraryCoordinator
    @ObservedObject var dynamicDesktopStartup:
        DynamicDesktopStartupController
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isFullScreen: Bool
    @ObservedObject var chromeController: PlayerChromeController
    let actions: PlayerActions
    let playerSurface: PlayerSurface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        ZStack {
            MuralumeTheme.Colors.canvas

            VideoViewport(
                playback: playback,
                library: library,
                playerSurface: playerSurface
            )

            PointerActivityReader {
                chromeController.recordPointerActivity()
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
                .zIndex(5)
            }

            playerChrome
                .zIndex(4)

            playerTopBar
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .zIndex(6)
        }
        .animation(
            playerChromeAnimation,
            value: chromeController.presentedPanel
        )
        .frame(
            minWidth: AppConfiguration.minimumWindowWidth,
            minHeight: AppConfiguration.minimumWindowHeight
        )
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(chromePlaybackStatePublisher) { state in
            chromeController.updatePlaybackState(state)
        }
        .onChange(of: isFullScreen) {
            chromeController.updateFullScreen(isFullScreen)
        }
        .onAppear {
            chromeController.updateFullScreen(isFullScreen)
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
    }

    private var playerTopContentInset: CGFloat {
        MuralumeTheme.Size.playerTopBarHeight
            + MuralumeTheme.Spacing.large
    }

    private var playerChrome: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            Color.clear
                .frame(height: MuralumeTheme.Size.playerTopBarHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ZStack(alignment: .topTrailing) {
                sidePanel
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )

            playerControls
        }
        .padding(.horizontal, MuralumeTheme.Spacing.large)
        .padding(.bottom, MuralumeTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerControls: some View {
        PlayerControls(
            playback: playback,
            library: library,
            actions: actions,
            isPlaylistPresented: chromeController.isPlaylistPresented,
            togglePlaylist: {
                chromeController.togglePlaylist()
            }
        )
        .frame(
            maxWidth: MuralumeTheme.Size.playerControlsMaximumWidth
        )
        .offset(
            y: chromeController.isVisible
                ? 0
                : MuralumeTheme.Spacing.xLarge
        )
        .opacity(chromeController.isVisible ? 1 : 0)
        .allowsHitTesting(chromeController.isVisible)
        .accessibilityHidden(!chromeController.isVisible)
        .animation(
            playerChromeAnimation,
            value: chromeController.isVisible
        )
    }

    private var playerTopBar: some View {
        PlayerTopBar(
            playback: playback,
            isFullScreen: isFullScreen,
            isSettingsPresented: chromeController.isSettingsPresented,
            actions: actions
        )
        .offset(
            y: chromeController.isVisible
                ? 0
                : -MuralumeTheme.Spacing.xLarge
        )
        .opacity(chromeController.isVisible ? 1 : 0)
        .allowsHitTesting(chromeController.isVisible)
        .accessibilityHidden(!chromeController.isVisible)
        .environment(\.locale, locale)
        .preferredColorScheme(.dark)
        .animation(
            playerChromeAnimation,
            value: chromeController.isVisible
        )
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let panel = chromeController.presentedPanel {
            sidePanelContent(for: panel)
                .frame(width: sidePanelWidth(for: panel))
                .frame(maxHeight: .infinity)
                .muralumePanel(style: .playerOverlay)
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
        }
    }

    @ViewBuilder
    private func sidePanelContent(for panel: PlayerSidePanel) -> some View {
        switch panel {
        case .playlist:
            LibraryQueueSidebar(
                library: library,
                playback: playback,
                mediaThumbnailProvider: mediaThumbnailProvider,
                addFolders: actions.addFolders,
                dismiss: {
                    chromeController.setPlaylistPresented(false)
                }
            )
        case .settings:
            SettingsView(dynamicDesktopStartup: dynamicDesktopStartup) {
                chromeController.setSettingsPresented(false)
            }
        }
    }

    private func sidePanelWidth(for panel: PlayerSidePanel) -> CGFloat {
        switch panel {
        case .playlist:
            MuralumeTheme.Size.playlistOverlayWidth
        case .settings:
            MuralumeTheme.Size.settingsPanelWidth
        }
    }

    private var chromePlaybackStatePublisher:
        AnyPublisher<PlayerChromePlaybackState, Never> {
        Publishers.CombineLatest4(
            playback.$readiness,
            playback.$isActuallyPlaying,
            playback.$isPlaybackRequested,
            playback.$hasPlayableMedia
        )
        .combineLatest(playback.$isPlayerWindowDismissed)
        .map {
            playbackState,
            isPlayerWindowDismissed in
            let (
                readiness,
                isActuallyPlaying,
                isPlaybackRequested,
                hasPlayableMedia
            ) = playbackState
            return PlayerChromePlaybackState(
                readiness: readiness,
                isActuallyPlaying: isActuallyPlaying,
                isPlaybackRequested: isPlaybackRequested,
                hasPlayableMedia: hasPlayableMedia,
                isPlayerWindowDismissed: isPlayerWindowDismissed
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private var playerChromeAnimation: Animation? {
        reduceMotion
            ? nil
            : .easeOut(
                duration: MuralumeTheme.Motion
                    .playerChromeTransitionDuration
            )
    }
}
