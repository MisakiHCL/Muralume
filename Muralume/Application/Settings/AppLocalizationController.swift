import Combine
import Foundation

@MainActor
final class AppLocalizationController: ObservableObject {
    @Published private(set) var language: AppLanguage

    var locale: Locale {
        Locale(identifier: effectiveLanguage.rawValue)
    }

    var localizationDidChange: AnyPublisher<Void, Never> {
        localizationDidChangeSubject.eraseToAnyPublisher()
    }

    private let storage: any AppLanguageStoring
    private let resourcesBundle: Bundle
    private let preferredLanguages: () -> [String]
    private let localizationDidChangeSubject = PassthroughSubject<Void, Never>()
    private var systemLocaleChangeCancellable: AnyCancellable?

    init(
        storage: any AppLanguageStoring,
        resourcesBundle: Bundle = .main,
        preferredLanguages: @escaping () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.storage = storage
        self.resourcesBundle = resourcesBundle
        self.preferredLanguages = preferredLanguages
        language = storage.loadLanguage() ?? .system

        systemLocaleChangeCancellable = NotificationCenter.default.publisher(
            for: NSLocale.currentLocaleDidChangeNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemLocalization()
            }
        }
    }

    func selectLanguage(_ language: AppLanguage) {
        guard self.language != language else {
            return
        }
        self.language = language
        storage.saveLanguage(language)
        localizationDidChangeSubject.send()
    }

    func localized(_ key: String) -> String {
        localizedBundle.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
    }

    func localizedFormat(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: localized(key),
            locale: locale,
            arguments: arguments
        )
    }

    private var effectiveLanguage: AppLanguage {
        guard language == .system else {
            return language
        }

        let preferredLocalizations = Bundle.preferredLocalizations(
            from: AppLanguage.supportedLocalizationIdentifiers,
            forPreferences: preferredLanguages()
        )
        guard let identifier = preferredLocalizations.first,
              let language = AppLanguage(rawValue: identifier) else {
            return .english
        }
        return language
    }

    private var localizedBundle: Bundle {
        let identifier = effectiveLanguage.rawValue
        guard let path = resourcesBundle.path(
            forResource: identifier,
            ofType: "lproj"
        ),
        let bundle = Bundle(path: path) else {
            return resourcesBundle
        }
        return bundle
    }

    private func refreshSystemLocalization() {
        guard language == .system else {
            return
        }
        objectWillChange.send()
        localizationDidChangeSubject.send()
    }
}
