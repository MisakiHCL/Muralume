import Combine
import SwiftUI

enum PlayerFullScreenIcon {
    static let enterSystemName = "arrow.up.left.and.arrow.down.right"
    static let exitSystemName = "arrow.down.right.and.arrow.up.left"

    static func systemName(isFullScreen: Bool) -> String {
        isFullScreen ? exitSystemName : enterSystemName
    }
}

struct PlayerControlBar: View {
    let playback: PlaybackCoordinator
    let library: MediaLibraryCoordinator
    let actions: PlayerActions
    let isFullScreen: Bool
    let isPlaylistPresented: Bool
    let togglePlaylist: () -> Void

    @State private var controlState: PlayerControlState

    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator,
        actions: PlayerActions,
        isFullScreen: Bool,
        isPlaylistPresented: Bool,
        togglePlaylist: @escaping () -> Void
    ) {
        self.playback = playback
        self.library = library
        self.actions = actions
        self.isFullScreen = isFullScreen
        self.isPlaylistPresented = isPlaylistPresented
        self.togglePlaylist = togglePlaylist
        _controlState = State(
            initialValue: PlayerControlState(
                playback: playback,
                library: library
            )
        )
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideControlBar
                .frame(
                    minWidth: MuralumeTheme.Size
                        .widePlayerControlsMinimumWidth
                )

            compactControlBar
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playerControlBar
        )
        .onReceive(controlStatePublisher) { state in
            controlState = state
        }
    }

    private var wideControlBar: some View {
        ZStack {
            HStack(spacing: MuralumeTheme.Spacing.medium) {
                leadingControls(showsVolumeSlider: true)

                Spacer(minLength: MuralumeTheme.Spacing.large)

                trailingControls
            }

            transportControls
        }
    }

    private var compactControlBar: some View {
        ZStack {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                leadingControls(showsVolumeSlider: false)

                Spacer(minLength: MuralumeTheme.Spacing.large)

                trailingControls
            }

            compactTransportControls
        }
    }

    private var compactTransportControls: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            previousItemButton
            playbackToggleButton
            nextItemButton
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playerTransportControls
        )
    }

    private var transportControls: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            previousItemButton

            Button {
                playback.skip(by: -PlaybackPolicy.seekStepSeconds)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("player.back"))
            .accessibilityLabel(Text("player.back"))
            .disabled(!mediaControlsEnabled)

            playbackToggleButton

            Button {
                playback.skip(by: PlaybackPolicy.seekStepSeconds)
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("player.forward"))
            .accessibilityLabel(Text("player.forward"))
            .disabled(!mediaControlsEnabled)

            nextItemButton
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playerTransportControls
        )
    }

    private var previousItemButton: some View {
        Button {
            library.playPrevious()
        } label: {
            Image(systemName: "backward.end.fill")
        }
        .buttonStyle(MuralumeControlButtonStyle())
        .help(Text("player.previousItem"))
        .accessibilityLabel(Text("player.previousItem"))
        .disabled(
            !globalControlsEnabled || !controlState.canMoveToPrevious
        )
    }

    private var playbackToggleButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Image(
                systemName: controlState.isPlaybackRequested
                    ? "pause.fill"
                    : "play.fill"
            )
            .offset(x: controlState.isPlaybackRequested ? 0 : 1)
        }
        .buttonStyle(MuralumeControlButtonStyle(kind: .prominent))
        .help(playbackToggleLabel)
        .accessibilityLabel(playbackToggleLabel)
        .disabled(!mediaControlsEnabled)
    }

    private var nextItemButton: some View {
        Button {
            library.playNext()
        } label: {
            Image(systemName: "forward.end.fill")
        }
        .buttonStyle(MuralumeControlButtonStyle())
        .help(Text("player.nextItem"))
        .accessibilityLabel(Text("player.nextItem"))
        .disabled(
            !globalControlsEnabled || !controlState.hasActiveQueue
        )
    }

    private func leadingControls(
        showsVolumeSlider: Bool
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            volumeControls(showsSlider: showsVolumeSlider)
            playbackOrderButton
        }
        .fixedSize()
    }

    private func volumeControls(showsSlider: Bool) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Button {
                playback.setMuted(!controlState.settings.isMuted)
            } label: {
                Image(systemName: volumeIconName)
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(muteToggleLabel)
            .accessibilityLabel(muteToggleLabel)
            .disabled(!globalControlsEnabled)

            if showsSlider {
                MuralumeSlider(
                    value: Binding(
                        get: {
                            Double(controlState.settings.volume.rawValue)
                        },
                        set: {
                            playback.setVolume(
                                PlaybackVolume(rawValue: Float($0))
                            )
                        }
                    ),
                    in: 0...1,
                    kind: .volume,
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier.volumeSlider
                )
                .frame(
                    width: MuralumeTheme.Size.volumeSliderWidth,
                    height: MuralumeTheme.Size.sliderHitTargetHeight
                )
                .disabled(!globalControlsEnabled)
                .accessibilityLabel(Text("player.volume"))
                .accessibilityValue(
                    Text(
                        verbatim: PlayerFormatting.volume(
                            controlState.settings.volume
                        )
                    )
                )
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.volumeSlider
                )
            }
        }
        .fixedSize()
    }

    private var playbackOrderButton: some View {
        let isShuffled = controlState.playbackOrder == .shuffled

        return Button {
            library.setPlaybackOrder(isShuffled ? .ordered : .shuffled)
        } label: {
            Image(systemName: isShuffled ? "shuffle" : "list.number")
        }
        .buttonStyle(
            MuralumeControlButtonStyle(
                kind: isShuffled ? .selected : .standard
            )
        )
        .help(Text(LocalizedStringKey(playbackOrderLabelKey)))
        .accessibilityLabel(
            Text(LocalizedStringKey(playbackOrderLabelKey))
        )
        .accessibilityAddTraits(isShuffled ? .isSelected : [])
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playbackOrderButton
        )
        .disabled(!globalControlsEnabled)
    }

    private var trailingControls: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            playbackRateMenu

            Button {
                actions.toggleFullScreen()
            } label: {
                Image(
                    systemName: PlayerFullScreenIcon.systemName(
                        isFullScreen: isFullScreen
                    )
                )
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("player.fullscreen"))
            .accessibilityLabel(Text("player.fullscreen"))
            .disabled(!globalControlsEnabled)

            playlistButton

            Button {
                actions.enterDesktop()
            } label: {
                Image(systemName: "display")
            }
            .buttonStyle(MuralumeControlButtonStyle(kind: .accent))
            .help(Text("player.desktop"))
            .accessibilityLabel(Text("player.desktop"))
            .disabled(!mediaControlsEnabled)
        }
        .fixedSize()
    }

    private var playlistButton: some View {
        Button(action: togglePlaylist) {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(
            MuralumeControlButtonStyle(
                kind: isPlaylistPresented ? .selected : .standard
            )
        )
        .help(Text(LocalizedStringKey(playlistToggleLabelKey)))
        .accessibilityLabel(
            Text(LocalizedStringKey(playlistToggleLabelKey))
        )
        .accessibilityAddTraits(
            isPlaylistPresented ? .isSelected : []
        )
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playlistToggleButton
        )
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(PlaybackPolicy.supportedRates, id: \.self) { rate in
                Button(PlayerFormatting.rate(rate)) {
                    playback.setRate(rate)
                }
            }
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                Text(
                    verbatim: PlayerFormatting.rate(
                        controlState.settings.rate
                    )
                )
                    .font(.body.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(MuralumeTheme.Colors.textPrimary)
            .padding(.horizontal, MuralumeTheme.Spacing.small)
            .frame(height: MuralumeTheme.Size.control)
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(MuralumeTheme.Colors.controlFill)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!globalControlsEnabled)
        .help(Text("player.speed"))
        .accessibilityLabel(Text("player.speed"))
        .accessibilityValue(
            Text(
                verbatim: PlayerFormatting.rate(
                    controlState.settings.rate
                )
            )
        )
    }

    private var playbackToggleLabel: Text {
        Text(
            LocalizedStringKey(
                controlState.isPlaybackRequested
                    ? "player.pause"
                    : "player.play"
            )
        )
    }

    private var muteToggleLabel: Text {
        Text(
            LocalizedStringKey(
                controlState.settings.isMuted
                    ? "player.unmute"
                    : "player.mute"
            )
        )
    }

    private var volumeIconName: String {
        if controlState.settings.isMuted {
            return "speaker.slash.fill"
        }
        return controlState.settings.volume == .muted
            ? "speaker.fill"
            : "speaker.wave.2.fill"
    }

    private var playbackOrderLabelKey: String {
        controlState.playbackOrder == .ordered
            ? "queue.order.ordered"
            : "queue.order.shuffled"
    }

    private var playlistToggleLabelKey: String {
        isPlaylistPresented
            ? "library.playlist.hide"
            : "library.playlist.show"
    }

    private var globalControlsEnabled: Bool {
        controlState.presentation == .player
    }

    private var mediaControlsEnabled: Bool {
        globalControlsEnabled && controlState.hasPlayableMedia
    }

    private var controlStatePublisher:
        AnyPublisher<PlayerControlState, Never> {
        Publishers.CombineLatest(
            playbackControlStatePublisher,
            libraryControlStatePublisher
        )
        .map { playbackState, libraryState in
            PlayerControlState(
                playback: playbackState,
                library: libraryState
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private var playbackControlStatePublisher:
        AnyPublisher<PlayerPlaybackControlState, Never> {
        Publishers.CombineLatest4(
            playback.$hasPlayableMedia,
            playback.$presentation,
            playback.$isPlaybackRequested,
            playback.$settings
        )
        .map {
            PlayerPlaybackControlState(
                hasPlayableMedia: $0,
                presentation: $1,
                isPlaybackRequested: $2,
                settings: $3
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private var libraryControlStatePublisher:
        AnyPublisher<PlayerLibraryControlState, Never> {
        library.objectWillChange
        .receive(on: RunLoop.main)
        .map {
            PlayerLibraryControlState(
                playbackOrder: library.playbackOrder,
                canMoveToPrevious: library.canMoveToPrevious,
                hasActiveQueue: library.hasActiveQueue
            )
        }
        .prepend(
            PlayerLibraryControlState(
                playbackOrder: library.playbackOrder,
                canMoveToPrevious: library.canMoveToPrevious,
                hasActiveQueue: library.hasActiveQueue
            )
        )
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}

private struct PlayerPlaybackControlState: Equatable {
    let hasPlayableMedia: Bool
    let presentation: PlaybackPresentation
    let isPlaybackRequested: Bool
    let settings: PlaybackSettings
}

private struct PlayerLibraryControlState: Equatable {
    let playbackOrder: PlaybackOrder
    let canMoveToPrevious: Bool
    let hasActiveQueue: Bool
}

private struct PlayerControlState: Equatable {
    let hasPlayableMedia: Bool
    let presentation: PlaybackPresentation
    let isPlaybackRequested: Bool
    let settings: PlaybackSettings
    let playbackOrder: PlaybackOrder
    let canMoveToPrevious: Bool
    let hasActiveQueue: Bool

    @MainActor
    init(
        playback: PlaybackCoordinator,
        library: MediaLibraryCoordinator
    ) {
        self.init(
            playback: PlayerPlaybackControlState(
                hasPlayableMedia: playback.hasPlayableMedia,
                presentation: playback.presentation,
                isPlaybackRequested: playback.isPlaybackRequested,
                settings: playback.settings
            ),
            library: PlayerLibraryControlState(
                playbackOrder: library.playbackOrder,
                canMoveToPrevious: library.canMoveToPrevious,
                hasActiveQueue: library.hasActiveQueue
            )
        )
    }

    init(
        playback: PlayerPlaybackControlState,
        library: PlayerLibraryControlState
    ) {
        hasPlayableMedia = playback.hasPlayableMedia
        presentation = playback.presentation
        isPlaybackRequested = playback.isPlaybackRequested
        settings = playback.settings
        playbackOrder = library.playbackOrder
        canMoveToPrevious = library.canMoveToPrevious
        hasActiveQueue = library.hasActiveQueue
    }
}
