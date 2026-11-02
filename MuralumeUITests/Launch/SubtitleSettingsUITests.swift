import XCTest

final class SubtitleSettingsUITests: XCTestCase {
    private enum Identifier {
        static let openSettings = "muralume.open-settings"
        static let categories = "muralume.settings-category-menu"
        static let fontPicker = "muralume.settings.subtitles.font-picker"
        static let preview = "muralume.settings.subtitles.preview"
        static let restoreDefaults = "muralume.settings.subtitles.restore-defaults"
    }

    @MainActor
    func testSubtitleCategoryAndNativeFontMenuInEnglishAndChinese() throws {
        for language in ["en", "zh-Hans"] {
            let application = try MuralumeUITestSession.makeApplication(for: Self.self)
            application.launchArguments += [
                "-ApplePersistenceIgnoreState", "YES",
                "-settings.app-language", language,
                "-settings.subtitles.font-family", "Menlo",
                "-media-library.source-records", "",
                "-media-library.root-bookmarks", ""
            ]
            defer { application.terminate() }
            try MuralumeUITestSession.launch(application, for: Self.self)
            application.activate()
            try require(element(Identifier.openSettings, in: application)).click()

            let categories = try require(element(Identifier.categories, in: application))
            let generalTitle = language == "en" ? "General" : "通用"
            let subtitleTitle = language == "en" ? "Subtitle Style" : "字幕样式"
            let systemTitle = language == "en" ? "System Font" : "系统字体"
            let fontLabel = language == "en" ? "Font" : "字体"
            for _ in 0..<3 {
                try require(category(subtitleTitle, in: categories)).click()
                _ = try require(element(Identifier.preview, in: application))
                let picker = try require(application.popUpButtons[Identifier.fontPicker])
                XCTAssertEqual(picker.label, fontLabel)
                XCTAssertEqual(picker.value as? String, "Menlo")
                try require(category(generalTitle, in: categories)).click()
            }

            try require(category(subtitleTitle, in: categories)).click()
            let picker = try require(application.popUpButtons[Identifier.fontPicker])
            XCTAssertTrue(picker.isEnabled)
            XCTAssertTrue(picker.isHittable)
            picker.click()
            try require(application.menuItems[systemTitle]).click()
            XCTAssertEqual(picker.value as? String, systemTitle)

            picker.click()
            try require(application.menuItems["Menlo"]).click()
            XCTAssertEqual(picker.value as? String, "Menlo")
            let restore = try require(element(Identifier.restoreDefaults, in: application))
            XCTAssertTrue(restore.isEnabled)
            restore.click()
            XCTAssertEqual(picker.value as? String, systemTitle)
            XCTAssertFalse(restore.isEnabled)
        }
    }

    @MainActor
    private func category(_ title: String, in categories: XCUIElement) -> XCUIElement {
        categories.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR title == %@", title, title)
        ).firstMatch
    }

    @MainActor
    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func require(_ element: XCUIElement) throws -> XCUIElement {
        if element.exists { return element }
        return try XCTUnwrap(element.waitForExistence(timeout: 5) ? element : nil)
    }
}
