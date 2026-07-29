import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let supportedLocalizationIdentifiers = [
        AppLanguage.english.rawValue,
        AppLanguage.simplifiedChinese.rawValue
    ]

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
        }
    }
}

@MainActor
protocol AppLanguageStoring: AnyObject {
    func loadLanguage() -> AppLanguage?
    func saveLanguage(_ language: AppLanguage)
}
