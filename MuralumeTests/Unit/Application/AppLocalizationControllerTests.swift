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

    func testFolderOverlapNoticesAreLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localized(
                "library.import.folderContainsActiveFolder"
            ),
            "A selected folder contains one or more subfolders already added "
                + "separately. Remove those subfolders from the library, "
                + "then try again."
        )
        XCTAssertEqual(
            controller.localized(
                "library.import.folderCoveredByActiveFolder"
            ),
            "The selected folder is already included in a folder in the "
                + "library, so it does not need to be added again."
        )

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(
            controller.localized(
                "library.import.folderContainsActiveFolder"
            ),
            "所选文件夹包含一个或多个已单独添加的子文件夹。"
                + "请先从媒体库移除这些子文件夹，然后重试。"
        )
        XCTAssertEqual(
            controller.localized(
                "library.import.folderCoveredByActiveFolder"
            ),
            "所选文件夹已位于媒体库的现有文件夹内，无需重复添加。"
        )
    }

    func testEmptyAndDropPromptsAreConciseAndLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localized("media.none.title"),
            "Add videos to start playing"
        )
        XCTAssertEqual(
            controller.localized("media.none.detail"),
            "Drop videos or folders here, or choose Add in the playlist."
        )
        XCTAssertEqual(
            controller.localized("library.summary.empty"),
            "0 videos"
        )
        XCTAssertEqual(
            controller.localized("library.empty.title"),
            "No playable videos found"
        )
        XCTAssertEqual(
            controller.localized("library.empty.detail"),
            "Try another video or folder."
        )
        XCTAssertEqual(
            controller.localized("library.playlist.empty"),
            "Videos will appear here"
        )
        XCTAssertEqual(
            controller.localized("library.drop.title"),
            "Drop to add videos"
        )

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(
            controller.localized("media.none.title"),
            "添加视频，开始播放"
        )
        XCTAssertEqual(
            controller.localized("media.none.detail"),
            "拖入视频或文件夹，或点按播放列表中的“添加”。"
        )
        XCTAssertEqual(
            controller.localized("library.summary.empty"),
            "0 个视频"
        )
        XCTAssertEqual(
            controller.localized("library.empty.title"),
            "未找到可播放的视频"
        )
        XCTAssertEqual(
            controller.localized("library.empty.detail"),
            "请尝试其他视频或文件夹。"
        )
        XCTAssertEqual(
            controller.localized("library.playlist.empty"),
            "视频将显示在这里"
        )
        XCTAssertEqual(
            controller.localized("library.drop.title"),
            "松开添加视频"
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
