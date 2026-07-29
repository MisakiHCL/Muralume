import XCTest
@testable import Muralume

@MainActor
final class AppLocalizationControllerTests: XCTestCase {
    func testDefaultsToSystemLanguageWhenStorageIsEmpty() {
        let storage = AppLanguageStoreDouble()

        let controller = AppLocalizationController(
            storage: storage,
            preferredLanguages: {
                ["en"]
            }
        )

        XCTAssertEqual(controller.language, .system)
        XCTAssertEqual(controller.locale.identifier, "en")
    }

    func testRestoresPersistedLanguage() {
        let storage = AppLanguageStoreDouble(language: .simplifiedChinese)

        let controller = AppLocalizationController(storage: storage)

        XCTAssertEqual(controller.language, .simplifiedChinese)
        XCTAssertEqual(controller.locale.identifier, "zh-Hans")
    }

    func testSelectionPersistsOnlyWhenItChanges() {
        let storage = AppLanguageStoreDouble(language: .system)
        let controller = AppLocalizationController(storage: storage)

        controller.selectLanguage(.system)
        controller.selectLanguage(.english)

        XCTAssertEqual(controller.language, .english)
        XCTAssertEqual(storage.savedLanguages, [.english])
    }

    func testExplicitLanguageSelectsMatchingLocalizationBundle() {
        let storage = AppLanguageStoreDouble(language: .english)
        let controller = AppLocalizationController(storage: storage)

        XCTAssertEqual(controller.localized("settings.title"), "Settings")

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(controller.localized("settings.title"), "设置")
    }

    func testLocalizedFormatUsesSelectedBundle() {
        let storage = AppLanguageStoreDouble(language: .simplifiedChinese)
        let controller = AppLocalizationController(storage: storage)

        XCTAssertEqual(
            controller.localizedFormat("library.video.count", 3),
            "3 个视频"
        )
    }

    func testInvalidPersistedLanguageFallsBackToSystem() throws {
        let suiteName = "com.muralume.tests.app-language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            "unsupported",
            forKey: AppLanguageStorageKey.selectedLanguage
        )

        let controller = AppLocalizationController(
            storage: UserDefaultsAppLanguageStore(userDefaults: defaults)
        )

        XCTAssertEqual(controller.language, .system)
    }

    func testUserDefaultsStorePersistsSelectionAcrossInstances() throws {
        let suiteName = "com.muralume.tests.app-language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        UserDefaultsAppLanguageStore(userDefaults: defaults)
            .saveLanguage(.simplifiedChinese)

        let restored = UserDefaultsAppLanguageStore(userDefaults: defaults)

        XCTAssertEqual(restored.loadLanguage(), .simplifiedChinese)
    }

    func testSystemLocaleChangeRefreshesFollowSystemLanguage() async {
        var preferredLanguages = ["en"]
        let storage = AppLanguageStoreDouble(language: .system)
        let controller = AppLocalizationController(
            storage: storage,
            preferredLanguages: {
                preferredLanguages
            }
        )

        XCTAssertEqual(controller.localized("settings.title"), "Settings")

        preferredLanguages = ["zh-Hans"]
        NotificationCenter.default.post(
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
        await Task.yield()

        XCTAssertEqual(controller.localized("settings.title"), "设置")
        XCTAssertEqual(controller.locale.identifier, "zh-Hans")
    }
}

@MainActor
private final class AppLanguageStoreDouble: AppLanguageStoring {
    private let language: AppLanguage?
    private(set) var savedLanguages: [AppLanguage] = []

    init(language: AppLanguage? = nil) {
        self.language = language
    }

    func loadLanguage() -> AppLanguage? {
        language
    }

    func saveLanguage(_ language: AppLanguage) {
        savedLanguages.append(language)
    }
}
