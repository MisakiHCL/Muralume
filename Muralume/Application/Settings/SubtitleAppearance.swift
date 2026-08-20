import Combine
import Foundation

struct SubtitleColorValue: Equatable, Sendable {
    static let white = SubtitleColorValue(
        red: 255,
        green: 255,
        blue: 255,
        alpha: 255
    )
    static let black = SubtitleColorValue(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 255
    )

    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var storageValue: String {
        String(
            format: "%02X%02X%02X%02X",
            red,
            green,
            blue,
            alpha
        )
    }

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(storageValue: String) {
        let normalized = storageValue.hasPrefix("#")
            ? String(storageValue.dropFirst())
            : storageValue
        guard normalized.count == 8,
              let rawValue = UInt32(normalized, radix: 16) else {
            return nil
        }
        self.init(
            red: UInt8((rawValue >> 24) & 0xFF),
            green: UInt8((rawValue >> 16) & 0xFF),
            blue: UInt8((rawValue >> 8) & 0xFF),
            alpha: UInt8(rawValue & 0xFF)
        )
    }
}

struct SubtitleAppearancePreferences: Equatable, Sendable {
    static let maximumFontFamilyNameLength = 128

    static let defaultValue = SubtitleAppearancePreferences(
        fontFamilyName: nil,
        textColor: .white,
        shadowColor: .black
    )

    let fontFamilyName: String?
    let textColor: SubtitleColorValue
    let shadowColor: SubtitleColorValue

    init(
        fontFamilyName: String?,
        textColor: SubtitleColorValue,
        shadowColor: SubtitleColorValue
    ) {
        self.fontFamilyName = Self.normalizedFontFamilyName(
            fontFamilyName
        )
        self.textColor = textColor
        self.shadowColor = shadowColor
    }

    private static func normalizedFontFamilyName(
        _ fontFamilyName: String?
    ) -> String? {
        guard let fontFamilyName else {
            return nil
        }
        let trimmed = fontFamilyName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maximumFontFamilyNameLength))
    }
}

@MainActor
final class SubtitleAppearanceController: ObservableObject {
    @Published private(set) var preferences: SubtitleAppearancePreferences

    var preferencesDidChangeHandler:
        ((SubtitleAppearancePreferences) -> Void)?

    private let store: (any AppPreferencesStoring)?

    init(
        preferences: SubtitleAppearancePreferences = .defaultValue,
        store: (any AppPreferencesStoring)? = nil
    ) {
        self.preferences = preferences
        self.store = store
    }

    func setFontFamilyName(_ fontFamilyName: String?) {
        update(
            SubtitleAppearancePreferences(
                fontFamilyName: fontFamilyName,
                textColor: preferences.textColor,
                shadowColor: preferences.shadowColor
            )
        )
    }

    func setTextColor(_ color: SubtitleColorValue) {
        update(
            SubtitleAppearancePreferences(
                fontFamilyName: preferences.fontFamilyName,
                textColor: color,
                shadowColor: preferences.shadowColor
            )
        )
    }

    func setShadowColor(_ color: SubtitleColorValue) {
        update(
            SubtitleAppearancePreferences(
                fontFamilyName: preferences.fontFamilyName,
                textColor: preferences.textColor,
                shadowColor: color
            )
        )
    }

    func restoreDefaults() {
        update(.defaultValue)
    }

    private func update(_ updatedPreferences: SubtitleAppearancePreferences) {
        guard updatedPreferences != preferences else {
            return
        }
        preferences = updatedPreferences
        store?.saveSubtitleAppearance(updatedPreferences)
        preferencesDidChangeHandler?(updatedPreferences)
    }
}
