import AppKit
import SwiftUI

struct SubtitleAppearanceSettingsView: View {
    @ObservedObject var appearance: SubtitleAppearanceController

    private let availableFontFamilies: [String]

    init(appearance: SubtitleAppearanceController) {
        self.appearance = appearance
        var fontFamilies = Set(
            NSFontManager.shared.availableFontFamilies.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.count
                        <= SubtitleAppearancePreferences
                            .maximumFontFamilyNameLength
            }
        )
        if let selectedFamily = appearance.preferences.fontFamilyName {
            fontFamilies.insert(selectedFamily)
        }
        availableFontFamilies = fontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        SettingsSection(
            title: "settings.subtitles.title",
            accessibilityIdentifier:
                MuralumeAccessibilityIdentifier.settingsSubtitleSection
        ) {
            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.medium
            ) {
                Text("settings.subtitles.description")
                    .font(.callout)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SubtitleAppearancePreview(
                    preferences: appearance.preferences
                )

                SettingsRow(
                    title: "settings.subtitles.font",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsSubtitleFontRow
                ) {
                    fontPicker
                }

                SettingsRow(
                    title: "settings.subtitles.textColor",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsSubtitleTextColorRow
                ) {
                    ColorPicker(
                        "settings.subtitles.textColor",
                        selection: textColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .accessibilityLabel(
                        Text("settings.subtitles.textColor")
                    )
                }

                SettingsRow(
                    title: "settings.subtitles.shadowColor",
                    accessibilityIdentifier:
                        MuralumeAccessibilityIdentifier
                            .settingsSubtitleShadowColorRow
                ) {
                    ColorPicker(
                        "settings.subtitles.shadowColor",
                        selection: shadowColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .accessibilityLabel(
                        Text("settings.subtitles.shadowColor")
                    )
                }

                HStack {
                    Spacer()
                    Button("settings.subtitles.restoreDefaults") {
                        appearance.restoreDefaults()
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        appearance.preferences == .defaultValue
                    )
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier
                            .subtitleRestoreDefaultsButton
                    )
                }
                .padding(.horizontal, MuralumeTheme.Spacing.small)
            }
        }
    }

    private var fontPicker: some View {
        Picker(
            "settings.subtitles.font",
            selection: fontFamilyBinding
        ) {
            Text("settings.subtitles.font.system")
                .tag(String?.none)
            ForEach(availableFontFamilies, id: \.self) { fontFamily in
                Text(verbatim: fontFamily)
                    .tag(Optional(fontFamily))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
        .accessibilityLabel(Text("settings.subtitles.font"))
    }

    private var fontFamilyBinding: Binding<String?> {
        Binding(
            get: { appearance.preferences.fontFamilyName },
            set: { appearance.setFontFamilyName($0) }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { appearance.preferences.textColor.swiftUIColor },
            set: {
                appearance.setTextColor(
                    SubtitleColorValue(swiftUIColor: $0)
                )
            }
        )
    }

    private var shadowColorBinding: Binding<Color> {
        Binding(
            get: { appearance.preferences.shadowColor.swiftUIColor },
            set: {
                appearance.setShadowColor(
                    SubtitleColorValue(swiftUIColor: $0)
                )
            }
        )
    }
}

private struct SubtitleAppearancePreview: View {
    let preferences: SubtitleAppearancePreferences

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.12, blue: 0.18),
                    Color(red: 0.24, green: 0.30, blue: 0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text("settings.subtitles.preview.text")
                .font(previewFont)
                .foregroundStyle(preferences.textColor.swiftUIColor)
                .multilineTextAlignment(.center)
                .shadow(
                    color: preferences.shadowColor.swiftUIColor,
                    radius: MuralumeTheme.Subtitle.shadowRadius,
                    x: MuralumeTheme.Subtitle.shadowOffset.width,
                    y: MuralumeTheme.Subtitle.shadowOffset.height
                )
                .padding(.horizontal, MuralumeTheme.Spacing.medium)
                .padding(.bottom, MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("settings.subtitles.preview"))
        .accessibilityValue(Text("settings.subtitles.preview.text"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.subtitleAppearancePreview
        )
    }

    private var previewFont: Font {
        if let fontFamilyName = preferences.fontFamilyName {
            return .custom(
                fontFamilyName,
                size: MuralumeTheme.Subtitle.fontSize
            ).weight(.semibold)
        }
        return .system(
            size: MuralumeTheme.Subtitle.fontSize,
            weight: .semibold
        )
    }
}

extension SubtitleColorValue {
    init(swiftUIColor: Color) {
        let resolvedColor = NSColor(swiftUIColor).usingColorSpace(.sRGB)
            ?? NSColor.white
        self.init(
            red: Self.byte(resolvedColor.redComponent),
            green: Self.byte(resolvedColor.greenComponent),
            blue: Self.byte(resolvedColor.blueComponent),
            alpha: Self.byte(resolvedColor.alphaComponent)
        )
    }

    private static func byte(_ component: CGFloat) -> UInt8 {
        let normalized = component.isFinite
            ? min(max(component, 0), 1)
            : 0
        return UInt8((normalized * 255).rounded())
    }
}
