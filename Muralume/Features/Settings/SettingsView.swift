import SwiftUI

struct SettingsView: View {
    @ObservedObject var localization: AppLocalizationController

    var body: some View {
        ZStack {
            MuralumeBackground()

            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xLarge) {
                header

                Divider()
                    .overlay(MuralumeTheme.Colors.border)

                languageSection

                Spacer(minLength: 0)
            }
            .padding(MuralumeTheme.Spacing.xLarge)
        }
        .frame(
            width: AppConfiguration.settingsWindowWidth,
            height: AppConfiguration.settingsWindowHeight
        )
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.settingsView
        )
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            MuralumeBrandMark(size: MuralumeTheme.Size.settingsBrandMark)

            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                Text("settings.title")
                    .font(.title2.weight(.bold))
                Text("settings.general")
                    .font(.body)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var languageSection: some View {
        HStack(alignment: .top, spacing: MuralumeTheme.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.small) {
                Text("settings.language")
                    .font(.headline)

                Text("settings.language.description")
                    .font(.body)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuralumeTheme.Spacing.large)

            languageMenu
        }
        .padding(MuralumeTheme.Spacing.large)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.medium)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    localization.selectLanguage(language)
                } label: {
                    if language == localization.language {
                        Label(
                            LocalizedStringKey(language.localizedKey),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(LocalizedStringKey(language.localizedKey))
                    }
                }
            }
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Text(
                    LocalizedStringKey(
                        localization.language.localizedKey
                    )
                )
                .font(.body.weight(.medium))
                .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.menuIndicator,
                            weight: .semibold
                        )
                    )
            }
            .foregroundStyle(MuralumeTheme.Colors.textPrimary)
            .padding(.horizontal, MuralumeTheme.Spacing.medium)
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
        .accessibilityLabel(Text("settings.language"))
        .accessibilityValue(
            Text(
                LocalizedStringKey(
                    localization.language.localizedKey
                )
            )
        )
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.languagePicker
        )
    }
}
