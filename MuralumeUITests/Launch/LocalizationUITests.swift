import XCTest

final class LocalizationUITests: XCTestCase {
    private enum Identifier {
        static let openSettings = "muralume.open-settings"
        static let settingsView = "muralume.settings-view"
        static let closeSettings = "muralume.settings-close"
        static let languagePicker = "muralume.language-picker"
    }

    private enum Timeout {
        static let control: TimeInterval = 5
    }

    private struct LanguageExpectation {
        let autonym: String
        let settingsTitle: String
        let closeSettings: String
        let aboutMenuTitle: String

        static let english = Self(
            autonym: "English", settingsTitle: "Settings",
            closeSettings: "Close Settings", aboutMenuTitle: "About Muralume"
        )

        static let all = [
            english,
            Self(autonym: "简体中文", settingsTitle: "设置",
                 closeSettings: "关闭设置", aboutMenuTitle: "关于 Muralume"),
            Self(autonym: "繁體中文", settingsTitle: "設定",
                 closeSettings: "關閉設定", aboutMenuTitle: "關於 Muralume"),
            Self(autonym: "日本語", settingsTitle: "設定",
                 closeSettings: "設定を閉じる", aboutMenuTitle: "Muralumeについて"),
            Self(autonym: "한국어", settingsTitle: "설정",
                 closeSettings: "설정 닫기", aboutMenuTitle: "Muralume에 관하여"),
            Self(autonym: "Français", settingsTitle: "Réglages",
                 closeSettings: "Fermer les réglages", aboutMenuTitle: "À propos de Muralume"),
            Self(autonym: "Deutsch", settingsTitle: "Einstellungen",
                 closeSettings: "Einstellungen schließen", aboutMenuTitle: "Über Muralume"),
            Self(autonym: "Español", settingsTitle: "Ajustes",
                 closeSettings: "Cerrar ajustes", aboutMenuTitle: "Acerca de Muralume"),
            Self(autonym: "Português (Brasil)", settingsTitle: "Ajustes",
                 closeSettings: "Fechar ajustes", aboutMenuTitle: "Sobre o Muralume"),
            Self(autonym: "Italiano", settingsTitle: "Impostazioni",
                 closeSettings: "Chiudi impostazioni", aboutMenuTitle: "Informazioni su Muralume")
        ]
    }

    @MainActor
    func testAllTenLanguagesUpdateSettingsAndAppMenuImmediately() throws {
        let application = try MuralumeUITestSession.makeApplication(for: type(of: self))
        application.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-settings.app-language", "en",
            "-media-library.source-records", "",
            "-media-library.root-bookmarks", ""
        ]
        defer { restoreEnglishAndTerminate(application) }
        try MuralumeUITestSession.launch(application, for: type(of: self))
        application.activate()
        _ = try XCTUnwrap(
            application.wait(for: .runningForeground, timeout: Timeout.control) ? true : nil,
            "The isolated localization test app must reach the foreground"
        )
        try require(element(Identifier.openSettings, in: application)).click()
        _ = try require(element(Identifier.settingsView, in: application))

        for language in LanguageExpectation.all {
            try selectLanguage(language.autonym, in: application)
            try assertSettings(language, in: application)
            try assertAboutMenu(language.aboutMenuTitle, in: application)
        }

        try selectLanguage(LanguageExpectation.english.autonym, in: application)
        try assertSettings(.english, in: application)
    }

    @MainActor
    private func selectLanguage(_ autonym: String, in application: XCUIApplication) throws {
        let picker = try require(element(Identifier.languagePicker, in: application))
        try requireUsable(picker)
        picker.click()
        let item = try require(application.menuItems.matching(
            displayedText(autonym)
        ).firstMatch)
        _ = try XCTUnwrap(item.isEnabled ? true : nil, "Language option must be enabled: \(autonym)")
        item.click()
        try waitForValue(autonym, on: element(Identifier.languagePicker, in: application))
    }

    @MainActor
    private func assertSettings(
        _ language: LanguageExpectation,
        in application: XCUIApplication
    ) throws {
        let settings = try require(element(Identifier.settingsView, in: application))
        _ = try require(settings.descendants(matching: .any).matching(
            displayedText(language.settingsTitle)
        ).firstMatch)
        let close = try require(element(Identifier.closeSettings, in: application))
        let localizedClose = XCTNSPredicateExpectation(
            predicate: displayedText(language.closeSettings), object: close
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [localizedClose], timeout: Timeout.control) == .completed ? true : nil,
            "Settings must update immediately for \(language.autonym)"
        )
        try requireUsable(close)
        let picker = try require(element(Identifier.languagePicker, in: application))
        try waitForValue(language.autonym, on: picker)
        try requireUsable(picker)
    }

    @MainActor
    private func assertAboutMenu(_ title: String, in application: XCUIApplication) throws {
        try require(application.menuBars.menuBarItems["Muralume"]).click()
        _ = try require(application.menuItems.matching(displayedText(title)).firstMatch)
        application.typeKey(.escape, modifierFlags: [])
        _ = try require(element(Identifier.settingsView, in: application))
    }

    @MainActor
    private func restoreEnglishAndTerminate(_ application: XCUIApplication) {
        guard application.state != .notRunning else { return }
        defer { application.terminate() }
        // If an assertion failed with a native menu open, dismiss only that
        // menu before recovering the isolated app's saved language preference.
        if application.menus.firstMatch.exists {
            application.typeKey(.escape, modifierFlags: [])
        }
        let settings = element(Identifier.settingsView, in: application)
        if !settings.exists {
            let openSettings = element(Identifier.openSettings, in: application)
            guard openSettings.exists && openSettings.isEnabled && openSettings.isHittable else { return }
            openSettings.click()
        }
        guard settings.waitForExistence(timeout: Timeout.control) else { return }
        let picker = element(Identifier.languagePicker, in: application)
        guard picker.waitForExistence(timeout: Timeout.control), picker.isEnabled, picker.isHittable else { return }
        if picker.value as? String == LanguageExpectation.english.autonym { return }
        picker.click()
        let english = application.menuItems.matching(displayedText(
            LanguageExpectation.english.autonym
        )).firstMatch
        guard english.waitForExistence(timeout: Timeout.control), english.isEnabled else { return }
        english.click()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", LanguageExpectation.english.autonym),
            object: element(Identifier.languagePicker, in: application)
        )
        _ = XCTWaiter.wait(for: [restored], timeout: Timeout.control)
    }

    private func displayedText(_ text: String) -> NSPredicate {
        NSPredicate(format: "title == %@ OR label == %@ OR value == %@", text, text, text)
    }

    @MainActor
    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func require(_ element: XCUIElement) throws -> XCUIElement {
        if element.exists { return element }
        return try XCTUnwrap(
            element.waitForExistence(timeout: Timeout.control) ? element : nil,
            "The expected localization control or text must exist"
        )
    }

    @MainActor
    private func requireUsable(_ element: XCUIElement) throws {
        if element.isEnabled && element.isHittable { return }
        let usable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: element
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [usable], timeout: Timeout.control) == .completed ? true : nil,
            "The localization control must remain enabled and clickable"
        )
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) throws {
        if element.exists && element.value as? String == value { return }
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [expected], timeout: Timeout.control) == .completed ? true : nil,
            "The language picker must show its selected autonym: \(value)"
        )
    }
}
