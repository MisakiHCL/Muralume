import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"

    static let supportedLocalizationIdentifiers = allCases
        .filter { $0 != .system }.map(\.rawValue)

    var id: Self {
        self
    }

    var localizedKey: String {
        switch self {
        case .system:
            "settings.language.system"
        case .english:
            "settings.language.english"
        case .simplifiedChinese:
            "settings.language.simplifiedChinese"
        case .traditionalChinese:
            "settings.language.traditionalChinese"
        case .japanese:
            "settings.language.japanese"
        case .korean:
            "settings.language.korean"
        case .french:
            "settings.language.french"
        case .german:
            "settings.language.german"
        case .spanish:
            "settings.language.spanish"
        case .brazilianPortuguese:
            "settings.language.brazilianPortuguese"
        case .italian:
            "settings.language.italian"
        }
    }
}
