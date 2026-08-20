import Combine
import SwiftUI

struct PlayerScreen<PlayerSurface: View>: View {
    let playback: PlaybackCoordinator
    @ObservedObject var desktopSession: DesktopSessionCoordinator
    @ObservedObject var desktopScene: DesktopSceneController
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playlists: CustomPlaylistController
    @ObservedObject var dynamicDesktopStartup:
        DynamicDesktopStartupController
    @ObservedObject var defaultVideoPlayer: DefaultVideoPlayerController
    @ObservedObject var smartPause: SmartPauseController
    let canRestoreDynamicDesktop: Bool
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isFullScreen: Bool
    @ObservedObject var chromeController: PlayerChromeController
    let actions: PlayerActions
    let playerSurface: PlayerSurface

    @State private var isMediaDropTargeted = false
    @State private var playlistNameEditor: PlaylistNameEditorRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        ZStack {
            Group {
                MuralumeTheme.Colors.canvas

                VideoViewport(
                    playback: playback,
                    library: library,
                    playerSurface: playerSurface
                )

                if chromeController.presentedPanel != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            chromeController.dismissPresentedPanel()
                        }
                        .accessibilityHidden(true)
                        .zIndex(PlayerLayer.panelDismiss)
                }

                PointerActivityReader {
                    chromeController.recordPointerActivity()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(PlayerLayer.pointerActivity)

                if library.importNotice != nil
                    || library.externalPlaybackNotice != nil
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

                        if let notice = library.externalPlaybackNotice {
                            PlayerStatusBanner(
                                message: externalPlaybackMessage(notice),
                                dismiss: {
                                    library.dismissExternalPlaybackNotice()
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
            .allowsHitTesting(
                !chromeController.isDesktopLayoutPresented
                    && playlistNameEditor == nil
            )
            .accessibilityHidden(
                chromeController.isDesktopLayoutPresented
                    || playlistNameEditor != nil
            )

            if chromeController.isDesktopLayoutPresented {
                desktopLayoutOverlay
                    .zIndex(PlayerLayer.desktopLayout)
                    .transition(.opacity)
            }

            if let request = playlistNameEditor {
                playlistNameEditorOverlay(request)
                    .zIndex(PlayerLayer.playlistNameEditor)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !chromeController.isDesktopLayoutPresented else {
                return false
            }
            return actions.importDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isMediaDropTargeted = isTargeted
                && !chromeController.isDesktopLayoutPresented
        }
        .animation(
            playerChromeAnimation,
            value: chromeController.presentedPanel
        )
        .animation(
            playerChromeAnimation,
            value: isMediaDropTargeted
        )
        .animation(
            playerChromeAnimation,
            value: chromeController.isDesktopLayoutPresented
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
        .onChange(of: chromeController.isDesktopLayoutPresented) {
            if chromeController.isDesktopLayoutPresented {
                isMediaDropTargeted = false
            }
        }
        .onAppear {
            chromeController.updateFullScreen(isFullScreen)
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
    }

    private func externalPlaybackMessage(
        _ notice: ExternalPlaybackNotice
    ) -> String {
        switch notice {
        case .noPlayableFiles:
            return localization.localized("external.open.none")
        case let .skippedFiles(count):
            let key = count == 1
                ? "external.open.skipped.one"
                : "external.open.skipped"
            return localization.localizedFormat(
                key,
                count
            )
        }
    }

    private var playerTopContentInset: CGFloat {
        MuralumeTheme.Size.playerTopBarHeight
            + MuralumeTheme.Spacing.large
    }

    private var desktopLayoutOverlay: some View {
        ZStack {
            Color.black.opacity(0.68)
                .contentShape(Rectangle())
                .ignoresSafeArea()

            DesktopLayoutView(
                desktopScene: desktopScene,
                items: library.items,
                currentItem: library.currentItem,
                mediaThumbnailProvider: mediaThumbnailProvider,
                cancel: actions.cancelDesktopLayout,
                apply: actions.applyDesktopLayout
            )
            .padding(MuralumeTheme.Spacing.xLarge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playlistNameEditorOverlay(
        _ request: PlaylistNameEditorRequest
    ) -> some View {
        ZStack {
            MuralumeTheme.Colors.modalScrim
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    playlistNameEditor = nil
                }

            PlaylistNameEditor(
                request: request,
                save: { name in
                    try savePlaylistName(name, for: request)
                },
                cancel: {
                    playlistNameEditor = nil
                },
                complete: {
                    playlistNameEditor = nil
                }
            )
            .id(request.id)
            .contentShape(Rectangle())
            .onTapGesture {}
            .environmentObject(localization)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            playlistNameEditor = nil
        }
    }

    private func savePlaylistName(
        _ name: String,
        for request: PlaylistNameEditorRequest
    ) throws {
        switch request {
        case .create:
            let playlistID = try playlists.createPlaylist(named: name)
            chromeController.librarySidebarController.selectDestination(
                .playlist(playlistID)
            )
        case let .rename(playlist):
            try playlists.renamePlaylist(id: playlist.id, to: name)
        }
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
            showsDesktopOptions: DesktopEntryControl.showsOptions(
                forConnectedDisplayCount:
                    desktopScene.connectedDisplays.count
            ),
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
            LibrarySidebar(
                library: library,
                playlists: playlists,
                navigation: chromeController.librarySidebarController,
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
                canRestoreDynamicDesktop: canRestoreDynamicDesktop,
                addTemporaryItemsToLibrary:
                    actions.addTemporaryItemsToLibrary,
                restoreDynamicDesktop: actions.restoreDynamicDesktop,
                playLibraryItem: actions.playLibraryItem,
                playCustomPlaylistItem:
                    actions.playCustomPlaylistItem,
                addLibraryItemToPlaylist:
                    actions.addLibraryItemToPlaylist,
                revealMediaInFinder: actions.revealMediaInFinder,
                dismiss: {
                    chromeController.setPlaylistPresented(false)
                },
                playlistNameEditor: $playlistNameEditor
            )
        case .settings:
            SettingsView(
                dynamicDesktopStartup: dynamicDesktopStartup,
                defaultVideoPlayer: defaultVideoPlayer,
                smartPause: smartPause,
                subtitleAppearance: playback.subtitleAppearance
            ) {
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
    static let panelDismiss = 2.0
    static let chrome = 4.0
    static let statusBanner = 5.0
    static let topBar = 6.0
    static let mediaDrop = 7.0
    static let desktopLayout = 8.0
    static let playlistNameEditor = 9.0
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
