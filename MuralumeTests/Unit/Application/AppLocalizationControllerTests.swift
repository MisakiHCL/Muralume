import XCTest
@testable import Muralume

@MainActor
final class AppLocalizationControllerTests: XCTestCase {
    func testDefaultsToSystemLanguageWhenNoInitialValueIsInjected() {
        let controller = AppLocalizationController(
            preferredLanguages: {
                ["en"]
            }
        )

        XCTAssertEqual(controller.language, .system)
        XCTAssertEqual(controller.locale.identifier, "en")
    }

    func testUsesInjectedLanguage() {
        let controller = AppLocalizationController(
            initialLanguage: .simplifiedChinese
        )

        XCTAssertEqual(controller.language, .simplifiedChinese)
        XCTAssertEqual(controller.locale.identifier, "zh-Hans")
    }

    func testSelectionPersistsOnlyWhenItChanges() {
        let preferencesStore = TestAppPreferencesStore()
        let controller = AppLocalizationController(
            initialLanguage: .system,
            preferencesStore: preferencesStore
        )

        controller.selectLanguage(.system)
        controller.selectLanguage(.english)

        XCTAssertEqual(controller.language, .english)
        XCTAssertEqual(preferencesStore.savedLanguages, [.english])
    }

    func testExplicitLanguageSelectsMatchingLocalizationBundle() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(controller.localized("settings.title"), "Settings")

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(controller.localized("settings.title"), "设置")
    }

    func testLocalizedFormatUsesSelectedBundle() {
        let controller = AppLocalizationController(
            initialLanguage: .simplifiedChinese
        )

        XCTAssertEqual(
            controller.localizedFormat("library.video.count", 3),
            "3 个视频"
        )
    }

    func testSystemLocaleChangeRefreshesFollowSystemLanguage() async {
        var preferredLanguages = ["en"]
        let controller = AppLocalizationController(
            initialLanguage: .system,
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
