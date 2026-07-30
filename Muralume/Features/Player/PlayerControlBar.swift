import SwiftUI

struct PlayerControlBar: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var library: MediaLibraryCoordinator
    let actions: PlayerActions
    let isPlaylistPresented: Bool
    let togglePlaylist: () -> Void

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
            .disabled(!controlsEnabled)

            playbackToggleButton

            Button {
                playback.skip(by: PlaybackPolicy.seekStepSeconds)
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("player.forward"))
            .accessibilityLabel(Text("player.forward"))
            .disabled(!controlsEnabled)

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
        .disabled(!controlsEnabled || !library.canMoveToPrevious)
    }

    private var playbackToggleButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Image(
                systemName: playback.isPlaybackRequested
                    ? "pause.fill"
                    : "play.fill"
            )
            .offset(x: playback.isPlaybackRequested ? 0 : 1)
        }
        .buttonStyle(MuralumeControlButtonStyle(kind: .prominent))
        .help(playbackToggleLabel)
        .accessibilityLabel(playbackToggleLabel)
        .disabled(!controlsEnabled)
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
        .disabled(!controlsEnabled || !library.hasActiveQueue)
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
                playback.setMuted(!playback.settings.isMuted)
            } label: {
                Image(systemName: volumeIconName)
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(muteToggleLabel)
            .accessibilityLabel(muteToggleLabel)
            .disabled(!controlsEnabled)

            if showsSlider {
                Slider(
                    value: Binding(
                        get: {
                            Double(playback.settings.volume.rawValue)
                        },
                        set: {
                            playback.setVolume(
                                PlaybackVolume(rawValue: Float($0))
                            )
                        }
                    ),
                    in: 0...1
                )
                .tint(MuralumeTheme.Colors.controlAccent)
                .frame(width: MuralumeTheme.Size.volumeSliderWidth)
                .disabled(!controlsEnabled)
                .accessibilityLabel(Text("player.volume"))
                .accessibilityValue(
                    Text(
                        verbatim: PlayerFormatting.volume(
                            playback.settings.volume
                        )
                    )
                )
            }
        }
        .fixedSize()
    }

    private var playbackOrderButton: some View {
        let isShuffled = library.playbackOrder == .shuffled

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
    }

    private var trailingControls: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            playbackRateMenu

            Button {
                actions.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(MuralumeControlButtonStyle())
            .help(Text("player.fullscreen"))
            .accessibilityLabel(Text("player.fullscreen"))
            .disabled(!controlsEnabled)

            playlistButton

            Button {
                actions.enterDesktop()
            } label: {
                Image(systemName: "display")
            }
            .buttonStyle(MuralumeControlButtonStyle(kind: .accent))
            .help(Text("player.desktop"))
            .accessibilityLabel(Text("player.desktop"))
            .disabled(!playback.canPresentOnDesktop || isTransitioning)
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
                Text(verbatim: PlayerFormatting.rate(playback.settings.rate))
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
        .disabled(!controlsEnabled)
        .help(Text("player.speed"))
        .accessibilityLabel(Text("player.speed"))
        .accessibilityValue(
            Text(verbatim: PlayerFormatting.rate(playback.settings.rate))
        )
    }

    private var playbackToggleLabel: Text {
        Text(
            LocalizedStringKey(
                playback.isPlaybackRequested
                    ? "player.pause"
                    : "player.play"
            )
        )
    }

    private var muteToggleLabel: Text {
        Text(
            LocalizedStringKey(
                playback.settings.isMuted
                    ? "player.unmute"
                    : "player.mute"
            )
        )
    }

    private var volumeIconName: String {
        if playback.settings.isMuted {
            return "speaker.slash.fill"
        }
        return playback.settings.volume == .muted
            ? "speaker.fill"
            : "speaker.wave.2.fill"
    }

    private var playbackOrderLabelKey: String {
        library.playbackOrder == .ordered
            ? "queue.order.ordered"
            : "queue.order.shuffled"
    }

    private var playlistToggleLabelKey: String {
        isPlaylistPresented
            ? "library.playlist.hide"
            : "library.playlist.show"
    }

    private var controlsEnabled: Bool {
        playback.readiness == .ready && !isTransitioning
    }

    private var isTransitioning: Bool {
        if case .switching = playback.presentation {
            return true
        }
        return false
    }
}
