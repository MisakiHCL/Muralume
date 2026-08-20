import SwiftUI

struct PlayerMediaSelectionMenu: View {
    @ObservedObject var controller: PlaybackMediaSelectionController
    @ObservedObject private var externalSubtitles: ExternalSubtitleController
    let isEnabled: Bool
    let loadExternalSubtitle: () -> Void

    init(
        controller: PlaybackMediaSelectionController,
        isEnabled: Bool,
        loadExternalSubtitle: @escaping () -> Void
    ) {
        self.controller = controller
        _externalSubtitles = ObservedObject(
            wrappedValue: controller.externalSubtitles
        )
        self.isEnabled = isEnabled
        self.loadExternalSubtitle = loadExternalSubtitle
    }

    var body: some View {
        if controller.state.showsTrackControls || controller.hasCurrentMedia {
            Menu {
                if !controller.state.audioOptions.isEmpty {
                    Section {
                        Button {
                            controller.selectAudio(.automatic)
                        } label: {
                            localizedSelectionLabel(
                                "player.tracks.automatic",
                                isSelected:
                                    controller.state.audioSelection
                                        == .automatic
                            )
                        }

                        ForEach(controller.state.audioOptions) { option in
                            Button {
                                controller.selectAudio(.option(option.id))
                            } label: {
                                optionSelectionLabel(
                                    option,
                                    isSelected:
                                        controller.state.audioSelection
                                            == .option(option.id)
                                )
                            }
                        }
                    } header: {
                        Text("player.tracks.audio")
                    }
                }

                if controller.hasCurrentMedia {
                    Section {
                        if controller.state.allowsEmptySubtitleSelection {
                            Button {
                                controller.selectSubtitles(.off)
                            } label: {
                                localizedSelectionLabel(
                                    "player.tracks.off",
                                    isSelected:
                                        externalSubtitles.track == nil
                                            && controller.state
                                                .subtitleSelection == .off
                                )
                            }
                        }

                        if !controller.state.subtitleOptions.isEmpty {
                            Button {
                                controller.selectSubtitles(.automatic)
                            } label: {
                                localizedSelectionLabel(
                                    "player.tracks.automatic",
                                    isSelected:
                                        externalSubtitles.track == nil
                                        && controller.state
                                            .subtitleSelection == .automatic
                                )
                            }
                        }

                        ForEach(controller.state.subtitleOptions) { option in
                            Button {
                                controller.selectSubtitles(.option(option.id))
                            } label: {
                                optionSelectionLabel(
                                    option,
                                    isSelected:
                                        externalSubtitles.track == nil
                                            && controller.state
                                                .subtitleSelection
                                                == .option(option.id)
                                )
                            }
                        }

                        Divider()

                        if let track = externalSubtitles.track {
                            Label {
                                Text(verbatim: track.displayName)
                            } icon: {
                                Image(systemName: "checkmark")
                            }

                            Button("player.tracks.external.remove") {
                                controller.removeExternalSubtitles()
                            }
                        }

                        Button(
                            "player.tracks.external.load",
                            action: loadExternalSubtitle
                        )

                        if externalSubtitles.isLoading {
                            Label(
                                "player.tracks.external.loading",
                                systemImage: "hourglass"
                            )
                        }

                        if let failure = externalSubtitles.failure {
                            Label {
                                Text(LocalizedStringKey(failure.localizedKey))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                        }
                    } header: {
                        Text("player.tracks.subtitles")
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.icon,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                    .frame(
                        width: MuralumeTheme.Size.control,
                        height: MuralumeTheme.Size.control
                    )
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
                            .stroke(
                                MuralumeTheme.Colors.border,
                                lineWidth: 1
                            )
                        }
                    }
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: MuralumeTheme.Radius.medium,
                            style: .continuous
                        )
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isEnabled)
            .help(Text("player.tracks"))
            .accessibilityLabel(Text("player.tracks"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.mediaSelectionButton
            )
        }
    }

    @ViewBuilder
    private func localizedSelectionLabel(
        _ key: String,
        isSelected: Bool
    ) -> some View {
        if isSelected {
            Label {
                Text(LocalizedStringKey(key))
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(LocalizedStringKey(key))
        }
    }

    @ViewBuilder
    private func optionSelectionLabel(
        _ option: PlaybackMediaOption,
        isSelected: Bool
    ) -> some View {
        if isSelected {
            Label {
                Text(verbatim: option.displayName)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(verbatim: option.displayName)
        }
    }
}
