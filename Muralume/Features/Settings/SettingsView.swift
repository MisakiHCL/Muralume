import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general

    var id: Self {
        self
    }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .general:
            "settings.general"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var selectedCategory = SettingsCategory.general
    @ObservedObject var dynamicDesktopStartup:
        DynamicDesktopStartupController

    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            header

            Divider()
                .overlay(MuralumeTheme.Colors.border)

            if SettingsCategory.allCases.count > 1 {
                categoryMenu
            }

            ScrollView {
                categoryContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(MuralumeTheme.Spacing.medium)
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.settingsView
        )
        .onAppear {
            dynamicDesktopStartup.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Label("settings.title", systemImage: "gearshape")
                .font(.headline)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: MuralumeTheme.Spacing.small)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.icon,
                            weight: .semibold
                        )
                    )
            }
            .buttonStyle(MuralumeToolbarButtonStyle())
            .help(Text("settings.close"))
            .accessibilityLabel(Text("settings.close"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.settingsCloseButton
            )
        }
        .frame(
            minHeight: MuralumeTheme.Size.control,
            alignment: .center
        )
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if category == selectedCategory {
                        Label(
                            category.localizedKey,
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(category.localizedKey)
                    }
                }
            }
        } label: {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: selectedCategory.systemImage)
                Text(selectedCategory.localizedKey)
                    .font(.body.weight(.medium))
                Spacer(minLength: MuralumeTheme.Spacing.small)
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
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.settingsCategoryMenu
        )
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .general:
            SettingsSection(
                title: "settings.general",
                accessibilityIdentifier:
                    MuralumeAccessibilityIdentifier.settingsGeneralSection
            ) {
                SettingsRow(
                    title: "settings.language",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier.settingsLanguageRow
                ) {
                    languageMenu
                }

                SettingsRow(
                    title: "settings.launchAtLogin",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsLaunchAtLoginRow
                ) {
                    launchAtLoginControl
                }
            }
        }
    }

    private var launchAtLoginControl: some View {
        VStack(alignment: .trailing, spacing: MuralumeTheme.Spacing.small) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                if dynamicDesktopStartup.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }

                Toggle(
                    "settings.launchAtLogin",
                    isOn: Binding(
                        get: {
                            dynamicDesktopStartup.isRequested
                        },
                        set: { isEnabled in
                            dynamicDesktopStartup.setEnabled(isEnabled)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(
                    dynamicDesktopStartup.isUpdating
                        || dynamicDesktopStartup.status.isUnavailable
                )
                .accessibilityLabel(Text("settings.launchAtLogin"))
                .accessibilityHint(
                    Text("settings.launchAtLogin.accessibilityHint")
                )
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.launchAtLoginCheckbox
                )
            }

            if let statusKey = launchAtLoginStatusKey {
                Text(statusKey)
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier.launchAtLoginStatus
                    )
            }

            if shouldOfferLoginItemSettings {
                Button("settings.launchAtLogin.openSystemSettings") {
                    dynamicDesktopStartup.openSystemSettings()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier
                        .launchAtLoginRecoveryButton
                )
            }
        }
        .frame(maxWidth: 220, alignment: .trailing)
    }

    private var launchAtLoginStatusKey: LocalizedStringKey? {
        if let failure = dynamicDesktopStartup.failure {
            return switch failure {
            case .selectMediaFirst:
                "settings.launchAtLogin.selectMediaFirst"
            case .presetUnavailable:
                "settings.launchAtLogin.presetUnavailable"
            case .enableFailed:
                "settings.launchAtLogin.enableFailed"
            case .disableFailed:
                "settings.launchAtLogin.disableFailed"
            case .automaticallyDisabled:
                "settings.launchAtLogin.automaticallyDisabled"
            case .manualDisableRequired:
                "settings.launchAtLogin.manualDisableRequired"
            }
        }
        return switch dynamicDesktopStartup.status {
        case .requiresApproval:
            "settings.launchAtLogin.requiresApproval"
        case let .unavailable(reason):
            switch reason {
            case .diskImage:
                "settings.launchAtLogin.unavailable.diskImage"
            case .outsideApplications:
                "settings.launchAtLogin.unavailable.outsideApplications"
            case .systemService:
                "settings.launchAtLogin.unavailable.systemService"
            }
        case .disabled, .enabled:
            nil
        }
    }

    private var shouldOfferLoginItemSettings: Bool {
        dynamicDesktopStartup.status == .requiresApproval
            || dynamicDesktopStartup.failure == .disableFailed
            || dynamicDesktopStartup.failure == .manualDisableRequired
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
        .accessibilityHint(Text("settings.language.description"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.languagePicker
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let accessibilityIdentifier: String
    let content: Content

    init(
        title: LocalizedStringKey,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(.vertical, MuralumeTheme.Spacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let accessibilityIdentifier: String
    let control: Control

    init(
        title: LocalizedStringKey,
        accessibilityIdentifier: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.control = control()
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: MuralumeTheme.Spacing.large
        ) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: MuralumeTheme.Spacing.large)

            control
        }
        .padding(.horizontal, MuralumeTheme.Spacing.large)
        .padding(.vertical, MuralumeTheme.Spacing.medium)
        .frame(
            maxWidth: .infinity,
            minHeight: MuralumeTheme.Size.settingsRowMinimumHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.52))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
