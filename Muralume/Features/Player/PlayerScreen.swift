import Combine
import SwiftUI

struct PlayerScreen<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    @ObservedObject var desktopSession: DesktopSessionCoordinator
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var dynamicDesktopStartup:
        DynamicDesktopStartupController
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isFullScreen: Bool
    @ObservedObject var chromeController: PlayerChromeController
    let actions: PlayerActions
    let playerSurface: PlayerSurface

    @State private var isMediaDropTargeted = false
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
            .zIndex(PlayerLayer.pointerActivity)

            if library.importNotice != nil
                || desktopSession.transientFailure != nil {
                VStack(spacing: MuralumeTheme.Spacing.small) {
                    if let notice = library.importNotice {
                        PlayerStatusBanner(
                            messageKey: notice.localizedKey,
                            dismiss: {
                                library.dismissImportNotice()
                            }
                        )
                    }

                    if let failure = desktopSession.transientFailure {
                        PlayerStatusBanner(
                            messageKey: failure.localizedKey,
                            dismiss: {
                                desktopSession.dismissTransientFailure()
                            }
                        )
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, MuralumeTheme.Spacing.large)
                .padding(.top, playerTopContentInset)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .zIndex(PlayerLayer.statusBanner)
            }

            playerChrome
                .zIndex(PlayerLayer.chrome)

            playerTopBar
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .zIndex(PlayerLayer.topBar)

            if isMediaDropTargeted {
                MediaDropOverlay()
                    .zIndex(PlayerLayer.mediaDrop)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.importDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isMediaDropTargeted = isTargeted
        }
        .animation(
            playerChromeAnimation,
            value: chromeController.presentedPanel
        )
        .animation(
            playerChromeAnimation,
            value: isMediaDropTargeted
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
        let isChromeVisible = isPlayerChromeVisible
        return PlayerControls(
            playback: playback,
            library: library,
            actions: actions,
            isFullScreen: isFullScreen,
            isPlaylistPresented: chromeController.isPlaylistPresented,
            togglePlaylist: {
                chromeController.togglePlaylist()
            }
        )
        .frame(
            maxWidth: MuralumeTheme.Size.playerControlsMaximumWidth
        )
        .offset(
            y: isChromeVisible
                ? 0
                : MuralumeTheme.Spacing.xLarge
        )
        .opacity(isChromeVisible ? 1 : 0)
        .allowsHitTesting(isChromeVisible)
        .accessibilityHidden(!isChromeVisible)
        .animation(
            playerChromeAnimation,
            value: isChromeVisible
        )
    }

    private var playerTopBar: some View {
        let isChromeVisible = isPlayerChromeVisible
        return PlayerTopBar(
            playback: playback,
            isFullScreen: isFullScreen,
            isSettingsPresented: chromeController.isSettingsPresented,
            actions: actions
        )
        .offset(
            y: isChromeVisible
                ? 0
                : -MuralumeTheme.Spacing.xLarge
        )
        .opacity(isChromeVisible ? 1 : 0)
        .allowsHitTesting(isChromeVisible)
        .accessibilityHidden(!isChromeVisible)
        .environment(\.locale, locale)
        .preferredColorScheme(.dark)
        .animation(
            playerChromeAnimation,
            value: isChromeVisible
        )
    }

    private var isPlayerChromeVisible: Bool {
        chromeController.isVisible
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
                isEditing: chromeController.isLibraryEditing,
                setEditing: { isEditing in
                    chromeController.setLibraryEditing(isEditing)
                },
                addMedia: actions.addMedia,
                retryUnavailableSourceAccess:
                    actions.retryUnavailableSourceAccess,
                reauthorizeMediaSources: actions.reauthorizeMediaSources,
                revealMediaInFinder: actions.revealMediaInFinder,
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

private enum PlayerLayer {
    static let pointerActivity = 1.0
    static let chrome = 4.0
    static let statusBanner = 5.0
    static let topBar = 6.0
    static let mediaDrop = 7.0
}

private struct MediaDropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.large
            )
            .fill(MuralumeTheme.Colors.controlFill)
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.large
                )
                .stroke(
                    MuralumeTheme.Colors.borderStrong,
                    lineWidth: 1
                )
            }
            .padding(MuralumeTheme.Spacing.small)

            Text("library.drop.title")
                .font(.title3.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .padding(.horizontal, MuralumeTheme.Spacing.xLarge)
                .padding(.vertical, MuralumeTheme.Spacing.large)
                .muralumePanel(cornerRadius: MuralumeTheme.Radius.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.mediaDropOverlay
        )
    }
}
