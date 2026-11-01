import Combine
import XCTest
@testable import Muralume

@MainActor
final class MultilingualLocalizationTests: XCTestCase {
    func testEverySupportedLanguageIsBundledAndCanBeSelectedImmediately() throws {
        let titles: [AppLanguage: String] = [
            .english: "Settings", .simplifiedChinese: "设置",
            .traditionalChinese: "設定", .japanese: "設定", .korean: "설정",
            .french: "Réglages", .german: "Einstellungen", .spanish: "Ajustes",
            .brazilianPortuguese: "Ajustes", .italian: "Impostazioni"
        ]
        XCTAssertEqual(Set(titles.keys.map(\.rawValue)), Set(AppLanguage.supportedLocalizationIdentifiers))
        XCTAssertEqual(Set(Bundle.main.localizations).subtracting(["Base"]), Set(titles.keys.map(\.rawValue)))
        let store = TestAppPreferencesStore()
        let controller = AppLocalizationController(preferencesStore: store)
        var notifications = 0
        let observation = controller.localizationDidChange.sink { notifications += 1 }
        for language in AppLanguage.allCases where language != .system {
            controller.selectLanguage(language)
            XCTAssertEqual(controller.locale.identifier, language.rawValue)
            XCTAssertEqual(controller.localized("settings.title"), titles[language], language.rawValue)
            XCTAssertEqual(store.savedLanguages.last, language)
            XCTAssertNotEqual(controller.localized(language.localizedKey), language.localizedKey)
            _ = try table(for: language.rawValue, fileExtension: "stringsdict")
        }
        XCTAssertEqual(notifications, titles.count)
        observation.cancel()
    }

    func testSystemLanguageMatchesRegionalPreferencesAndTraditionalChinese() {
        let cases: [([String], AppLanguage)] = [
            (["ja-JP"], .japanese), (["ko-KR"], .korean),
            (["fr-CA"], .french), (["de-AT"], .german),
            (["es-MX"], .spanish), (["pt-BR"], .brazilianPortuguese),
            (["pt-PT"], .brazilianPortuguese), (["it-CH"], .italian),
            (["zh-TW"], .traditionalChinese), (["zh-HK"], .traditionalChinese),
            (["zh-CN"], .simplifiedChinese), (["zz-ZZ", "fr-FR"], .french),
            (["zz-ZZ"], .english)
        ]
        for (preferences, expected) in cases {
            let controller = AppLocalizationController(preferredLanguages: { preferences })
            XCTAssertEqual(controller.language, .system)
            XCTAssertEqual(controller.locale.identifier, expected.rawValue, preferences.joined(separator: ", "))
        }
    }

    func testCountsUseTheSelectedLanguagesNativePluralRules() {
        let cases: [(AppLanguage, [String])] = [
            (.english, ["0 videos", "1 video", "2 videos"]),
            (.simplifiedChinese, ["0 个视频", "1 个视频", "2 个视频"]),
            (.traditionalChinese, ["0 部影片", "1 部影片", "2 部影片"]),
            (.japanese, ["動画0本", "動画1本", "動画2本"]),
            (.korean, ["동영상 0개", "동영상 1개", "동영상 2개"]),
            (.french, ["0 vidéo", "1 vidéo", "2 vidéos"]),
            (.german, ["0 Videos", "1 Video", "2 Videos"]),
            (.spanish, ["0 vídeos", "1 vídeo", "2 vídeos"]),
            (.brazilianPortuguese, ["0 vídeo", "1 vídeo", "2 vídeos"]),
            (.italian, ["0 video", "1 video", "2 video"])
        ]
        for (language, counts) in cases {
            let controller = AppLocalizationController(initialLanguage: language)
            for (count, expected) in counts.enumerated() {
                XCTAssertEqual(controller.localizedFormat("library.video.count", count), expected, language.rawValue)
            }
            XCTAssertEqual(controller.localizedFormat("videoInfo.value.duration.minutes", 2, 5), "2:05")
            XCTAssertEqual(controller.localizedFormat("videoInfo.value.duration.hours", 1, 2, 5), "1:02:05")
        }
    }

    func testAllTablesAndPluralMessagesArePresentInTheBuiltApp() throws {
        let english = try XCTUnwrap(try table(for: "en", fileExtension: "strings") as? [String: String])
        let englishPlurals = try table(for: "en", fileExtension: "stringsdict")
        for locale in AppLanguage.supportedLocalizationIdentifiers {
            let strings = try XCTUnwrap(try table(for: locale, fileExtension: "strings") as? [String: String])
            let plurals = try table(for: locale, fileExtension: "stringsdict")
            XCTAssertEqual(Set(strings.keys), Set(english.keys), locale)
            XCTAssertFalse(strings.values.contains(""), locale)
            XCTAssertEqual(Set(plurals.keys), Set(englishPlurals.keys), locale)
            let controller = AppLocalizationController(initialLanguage: try XCTUnwrap(AppLanguage(rawValue: locale)))
            for key in plurals.keys {
                for count in [0, 1, 2] {
                    let formatted = controller.localizedFormat(key, count)
                    XCTAssertFalse(formatted.isEmpty, "\(locale): \(key)")
                    XCTAssertFalse(formatted.contains("%#@"), "\(locale): \(key)")
                    XCTAssertNotEqual(formatted, key, locale)
                }
            }
        }
    }

    func testAllLanguagePreferencesSurviveNewStoreInstances() throws {
        let suite = "com.muralume.tests.languages.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for language in AppLanguage.allCases {
            UserDefaultsAppPreferencesStore(userDefaults: defaults).saveLanguage(language)
            XCTAssertEqual(UserDefaultsAppPreferencesStore(userDefaults: defaults).load().language, language)
        }
    }

    private func table(for locale: String, fileExtension: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "Localizable", withExtension: fileExtension,
            subdirectory: nil, localization: locale
        ))
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil
        ) as? [String: Any])
    }
}
