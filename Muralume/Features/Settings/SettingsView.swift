import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case subtitles

    var id: Self {
        self
    }

    var localizedKey: LocalizedStringKey {
        switch self {
        case .general:
            "settings.general"
        case .subtitles:
            "settings.subtitles.title"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .subtitles:
            "captions.bubble"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var selectedCategory = SettingsCategory.general
    @ObservedObject var dynamicDesktopStartup:
        DynamicDesktopStartupController
    @ObservedObject var defaultVideoPlayer: DefaultVideoPlayerController
    @ObservedObject var smartPause: SmartPauseController
    @ObservedObject var subtitleAppearance: SubtitleAppearanceController

    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            header

            Divider()
                .overlay(MuralumeTheme.Colors.border)

            if SettingsCategory.allCases.count > 1 {
                categoryPicker
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
            defaultVideoPlayer.refresh()
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

    private var categoryPicker: some View {
        Picker(
            "settings.category",
            selection: $selectedCategory
        ) {
            ForEach(SettingsCategory.allCases) { category in
                Label(
                    category.localizedKey,
                    systemImage: category.systemImage
                )
                .tag(category)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("settings.category"))
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

                SettingsRow(
                    title: "settings.defaultVideoPlayer",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsDefaultVideoPlayerRow
                ) {
                    defaultVideoPlayerControl
                }
            }

            smartPauseSection
        case .subtitles:
            SubtitleAppearanceSettingsView(
                appearance: subtitleAppearance
            )
        }
    }

    private var smartPauseSection: some View {
        SettingsSection(
            title: "settings.smartPause.title",
            accessibilityIdentifier:
                MuralumeAccessibilityIdentifier.settingsSmartPauseSection
        ) {
            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
                Text("settings.smartPause.description")
                    .font(.callout)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRow(
                    title: "settings.smartPause.enabled",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsSmartPauseEnabledRow
                ) {
                    smartPauseToggle(
                        label: "settings.smartPause.enabled",
                        identifier: MuralumeAccessibilityIdentifier
                            .smartPauseEnabledCheckbox,
                        isOn: Binding(
                            get: { smartPause.preferences.isEnabled },
                            set: { smartPause.setEnabled($0) }
                        )
                    )
                }

                smartPauseOptionsGroup

                Text("settings.smartPause.protections")
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var smartPauseOptionsGroup: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.small) {
            Text("settings.smartPause.conditions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .padding(.horizontal, MuralumeTheme.Spacing.medium)

            VStack(spacing: MuralumeTheme.Spacing.xSmall) {
                smartPauseOptionRow(
                    title: "settings.smartPause.desktopHidden",
                    rowIdentifier: MuralumeAccessibilityIdentifier
                        .settingsSmartPauseDesktopHiddenRow,
                    checkboxIdentifier: MuralumeAccessibilityIdentifier
                        .smartPauseDesktopHiddenCheckbox,
                    isOn: Binding(
                        get: {
                            smartPause.preferences.pauseWhenDesktopHidden
                        },
                        set: {
                            smartPause.setPauseWhenDesktopHidden($0)
                        }
                    )
                )
                smartPauseOptionRow(
                    title: "settings.smartPause.lowPowerMode",
                    rowIdentifier: MuralumeAccessibilityIdentifier
                        .settingsSmartPauseLowPowerModeRow,
                    checkboxIdentifier: MuralumeAccessibilityIdentifier
                        .smartPauseLowPowerModeCheckbox,
                    isOn: Binding(
                        get: {
                            smartPause.preferences.pauseInLowPowerMode
                        },
                        set: { smartPause.setPauseInLowPowerMode($0) }
                    )
                )
                smartPauseOptionRow(
                    title: "settings.smartPause.limitedPowerSource",
                    rowIdentifier: MuralumeAccessibilityIdentifier
                        .settingsSmartPauseLimitedPowerSourceRow,
                    checkboxIdentifier: MuralumeAccessibilityIdentifier
                        .smartPauseLimitedPowerSourceCheckbox,
                    isOn: Binding(
                        get: {
                            smartPause.preferences.pauseOnLimitedPowerSource
                        },
                        set: {
                            smartPause.setPauseOnLimitedPowerSource($0)
                        }
                    )
                )
                smartPauseOptionRow(
                    title: "settings.smartPause.sustainedSystemLoad",
                    rowIdentifier: MuralumeAccessibilityIdentifier
                        .settingsSmartPauseSustainedSystemLoadRow,
                    checkboxIdentifier: MuralumeAccessibilityIdentifier
                        .smartPauseSustainedSystemLoadCheckbox,
                    isOn: Binding(
                        get: {
                            smartPause.preferences
                                .pauseUnderSustainedSystemLoad
                        },
                        set: {
                            smartPause.setPauseUnderSustainedSystemLoad($0)
                        }
                    )
                )
            }
        }
        .padding(.leading, MuralumeTheme.Spacing.large)
        .padding(.trailing, MuralumeTheme.Spacing.small)
        .padding(.vertical, MuralumeTheme.Spacing.medium)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.28))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(MuralumeTheme.Colors.controlAccent.opacity(0.32))
                .frame(width: 2)
                .padding(.vertical, MuralumeTheme.Spacing.medium)
                .padding(.leading, MuralumeTheme.Spacing.small)
        }
        .disabled(!smartPause.preferences.isEnabled)
        .opacity(smartPause.preferences.isEnabled ? 1 : 0.48)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.settingsSmartPauseOptionsGroup
        )
    }

    private func smartPauseOptionRow(
        title: LocalizedStringKey,
        rowIdentifier: String,
        checkboxIdentifier: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Text(title)
                .font(.callout)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .lineLimit(1)
                .accessibilityHidden(true)

            Spacer(minLength: MuralumeTheme.Spacing.medium)

            smartPauseToggle(
                label: title,
                identifier: checkboxIdentifier,
                isOn: isOn
            )
        }
        .padding(.horizontal, MuralumeTheme.Spacing.medium)
        .padding(.vertical, MuralumeTheme.Spacing.small)
        .frame(
            maxWidth: .infinity,
            minHeight: MuralumeTheme.Size.settingsChildRowMinimumHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.small,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.4))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowIdentifier)
    }

    private func smartPauseToggle(
        label: LocalizedStringKey,
        identifier: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text("settings.smartPause.accessibilityHint"))
            .accessibilityIdentifier(identifier)
    }

    private var defaultVideoPlayerControl: some View {
        VStack(alignment: .trailing, spacing: MuralumeTheme.Spacing.small) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                if defaultVideoPlayer.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)

                    Text("settings.defaultVideoPlayer.action.updating")
                        .foregroundStyle(
                            MuralumeTheme.Colors.textSecondary
                        )
                        .accessibilityLabel(
                            Text(
                                "settings.defaultVideoPlayer.accessibility.updating"
                            )
                        )
                } else if defaultVideoPlayer.isDefault {
                    Label(
                        "settings.defaultVideoPlayer.action.complete",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                    .accessibilityLabel(
                        Text(
                            "settings.defaultVideoPlayer.accessibility.complete"
                        )
                    )
                } else {
                    Button(defaultVideoPlayerActionKey) {
                        Task {
                            await defaultVideoPlayer.setAsDefault()
                        }
                    }
                    .accessibilityLabel(
                        Text(
                            "settings.defaultVideoPlayer.accessibility.action"
                        )
                    )
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier
                            .setDefaultVideoPlayerButton
                    )
                }
            }

            if defaultVideoPlayer.operationFailure != nil {
                Text("settings.defaultVideoPlayer.failure")
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.error)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var defaultVideoPlayerActionKey: LocalizedStringKey {
        if defaultVideoPlayer.operationFailure != nil {
            return "settings.defaultVideoPlayer.action.retry"
        }
        switch defaultVideoPlayer.status {
        case .partial:
            return "settings.defaultVideoPlayer.action.partial"
        case .none, .all:
            return "settings.defaultVideoPlayer.action"
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

struct SettingsSection<Content: View>: View {
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

struct SettingsRow<Control: View>: View {
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
