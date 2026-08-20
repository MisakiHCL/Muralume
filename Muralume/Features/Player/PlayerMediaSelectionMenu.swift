import SwiftUI

struct PlayerMediaSelectionMenu: View {
    @ObservedObject var controller: PlaybackMediaSelectionController
    let isEnabled: Bool

    var body: some View {
        if controller.state.showsTrackControls {
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

                if !controller.state.subtitleOptions.isEmpty {
                    Section {
                        Button {
                            controller.selectSubtitles(.automatic)
                        } label: {
                            localizedSelectionLabel(
                                "player.tracks.automatic",
                                isSelected:
                                    controller.state.subtitleSelection
                                        == .automatic
                            )
                        }

                        if controller.state.allowsEmptySubtitleSelection {
                            Button {
                                controller.selectSubtitles(.off)
                            } label: {
                                localizedSelectionLabel(
                                    "player.tracks.off",
                                    isSelected:
                                        controller.state.subtitleSelection
                                            == .off
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
                                        controller.state.subtitleSelection
                                            == .option(option.id)
                                )
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
