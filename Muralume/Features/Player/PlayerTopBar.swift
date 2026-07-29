import SwiftUI

struct PlayerToolbar: ToolbarContent {
    @ObservedObject var playback: PlaybackCoordinator

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            informationalItems.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            informationalItems
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
        }

        settingsItem
    }

    @ToolbarContentBuilder
    private var informationalItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            brand
        }

        ToolbarItem(placement: .principal) {
            if let source = playback.source {
                currentSource(source.displayName)
            }
        }
    }

    private var settingsItem: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(
                        width: MuralumeTheme.Size.control,
                        height: MuralumeTheme.Size.control
                    )
            }
            .help(Text("settings.open"))
            .accessibilityLabel(Text("settings.open"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.openSettingsButton
            )
        }
    }

    private var brand: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            MuralumeBrandMark(
                size: MuralumeTheme.Size.toolbarBrandMark
            )

            Text("app.name")
                .font(.headline.weight(.bold))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("app.name"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.brandMark
        )
    }

    private func currentSource(_ displayName: String) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)

            Text(verbatim: displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, MuralumeTheme.Spacing.small)
        .frame(height: MuralumeTheme.Size.toolbarSourceHeight)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
    }
}
