import Foundation

enum AppLanguageStorageKey {
    static let selectedLanguage = "settings.app-language"
}

@MainActor
final class UserDefaultsAppLanguageStore: AppLanguageStoring {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadLanguage() -> AppLanguage? {
        guard let rawValue = userDefaults.string(
            forKey: AppLanguageStorageKey.selectedLanguage
        ) else {
            return nil
        }
        return AppLanguage(rawValue: rawValue)
    }

    func saveLanguage(_ language: AppLanguage) {
        userDefaults.set(
            language.rawValue,
            forKey: AppLanguageStorageKey.selectedLanguage
        )
    }
}
