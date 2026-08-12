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

    func testLocalizedMediaCountsUseSelectedBundle() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localizedFormat("library.video.count.one", 1),
            "1 video"
        )
        XCTAssertEqual(
            controller.localizedFormat("library.source.count", 3),
            "3 media sources"
        )
        XCTAssertEqual(
            controller.localizedFormat(
                "library.summary.accessibility",
                "1 video",
                "3 media sources"
            ),
            "1 video, 3 media sources"
        )
        XCTAssertEqual(
            controller.localizedFormat(
                "library.summary.accessibility.warning",
                "1 video, 3 media sources",
                "Some media sources are unavailable"
            ),
            "1 video, 3 media sources. Some media sources are unavailable."
        )

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(
            controller.localizedFormat("library.video.count", 3),
            "3 个视频"
        )
        XCTAssertEqual(
            controller.localizedFormat("library.source.count.one", 1),
            "1 个媒体来源"
        )
        XCTAssertEqual(
            controller.localizedFormat(
                "library.summary.accessibility",
                "3 个视频",
                "1 个媒体来源"
            ),
            "3 个视频，1 个媒体来源"
        )
        XCTAssertEqual(
            controller.localizedFormat(
                "library.summary.accessibility.warning",
                "3 个视频，1 个媒体来源",
                "部分媒体来源暂时不可用"
            ),
            "3 个视频，1 个媒体来源，部分媒体来源暂时不可用"
        )
    }

    func testFolderOverlapNoticesAreLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localized("library.import.unsupportedFormat"),
            "This file format is not supported yet."
        )
        XCTAssertEqual(
            controller.localized("library.import.unsupportedFormat.partial"),
            "Some file formats are not supported yet and were skipped."
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
            controller.localized("library.import.unsupportedFormat"),
            "暂不支持此文件格式。"
        )
        XCTAssertEqual(
            controller.localized("library.import.unsupportedFormat.partial"),
            "部分文件格式暂不支持，已跳过。"
        )
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
            "Drop videos or folders here, or use Add in the media library."
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
        XCTAssertEqual(
            controller.localized("library.media.picker.message"),
            "Choose videos or folders."
        )

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(
            controller.localized("media.none.title"),
            "添加视频，开始播放"
        )
        XCTAssertEqual(
            controller.localized("media.none.detail"),
            "拖入视频或文件夹，或点按媒体库中的“添加”。"
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
        XCTAssertEqual(
            controller.localized("library.media.picker.message"),
            "选择视频或文件夹"
        )
    }

    func testMediaLibraryAndPlayQueueTerminologyIsLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localized("library.playlist"),
            "Media Library"
        )
        XCTAssertEqual(
            controller.localized("library.playlist.show"),
            "Show Media Library"
        )
        XCTAssertEqual(
            controller.localized("library.playlist.hide"),
            "Hide Media Library"
        )
        XCTAssertEqual(controller.localized("queue.title"), "Play Queue")
        XCTAssertEqual(controller.localized("queue.upNext"), "Up Next")
        XCTAssertEqual(controller.localized("queue.showMore"), "Show More")
        XCTAssertEqual(controller.localized("queue.temporary"), "Temporary")
        XCTAssertEqual(
            controller.localized("queue.actions"),
            "Play Queue Actions"
        )
        XCTAssertEqual(
            controller.localizedFormat(
                "queue.item.accessibility.temporary",
                "Playing"
            ),
            "Playing, temporary item"
        )
        XCTAssertEqual(
            controller.localized("queue.addToLibrary"),
            "Add to Media Library"
        )

        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(controller.localized("library.playlist"), "媒体库")
        XCTAssertEqual(
            controller.localized("library.playlist.show"),
            "显示媒体库"
        )
        XCTAssertEqual(
            controller.localized("library.playlist.hide"),
            "隐藏媒体库"
        )
        XCTAssertEqual(controller.localized("queue.title"), "播放队列")
        XCTAssertEqual(controller.localized("queue.upNext"), "接下来播放")
        XCTAssertEqual(controller.localized("queue.showMore"), "显示更多")
        XCTAssertEqual(controller.localized("queue.temporary"), "临时")
        XCTAssertEqual(controller.localized("queue.actions"), "播放队列操作")
        XCTAssertEqual(
            controller.localizedFormat(
                "queue.item.accessibility.temporary",
                "正在播放"
            ),
            "正在播放，临时项目"
        )
        XCTAssertEqual(
            controller.localized("queue.addToLibrary"),
            "添加到媒体库"
        )
    }

    func testDefaultVideoPlayerSettingsAreLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer"),
            "Default Video Player"
        )
        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer.action"),
            "Set as Default"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.partial"
            ),
            "Finish Setup"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.retry"
            ),
            "Try Again"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.updating"
            ),
            "Setting…"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.complete"
            ),
            "Default"
        )
        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer.failure"),
            "Couldn’t set every format."
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.accessibility.action"
            ),
            "Make Muralume the default video player"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.accessibility.complete"
            ),
            "Muralume is the default video player"
        )
        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer"),
            "默认视频播放器"
        )
        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer.action"),
            "设为默认"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.partial"
            ),
            "完成设置"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.retry"
            ),
            "重试"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.updating"
            ),
            "正在设置…"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.action.complete"
            ),
            "已设为默认"
        )
        XCTAssertEqual(
            controller.localized("settings.defaultVideoPlayer.failure"),
            "未能设置全部格式。"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.accessibility.action"
            ),
            "将 Muralume 设为默认视频播放器"
        )
        XCTAssertEqual(
            controller.localized(
                "settings.defaultVideoPlayer.accessibility.complete"
            ),
            "Muralume 已设为默认视频播放器"
        )
    }

    func testPlayQueueNavigationAndExternalPlaybackFeedbackAreLocalized() {
        let controller = AppLocalizationController(
            initialLanguage: .english
        )

        XCTAssertEqual(controller.localized("queue.hide"), "Hide Play Queue")
        XCTAssertEqual(
            controller.localized("queue.navigation"),
            "Media Library or Play Queue"
        )
        XCTAssertEqual(
            controller.localized("queue.empty"),
            "The play queue is empty"
        )
        XCTAssertEqual(
            controller.localized("queue.empty.detail"),
            "Play a video from the media library or open one in Finder."
        )
        XCTAssertEqual(
            controller.localizedFormat("queue.upNext.count", 3),
            "3 up next"
        )
        XCTAssertEqual(controller.localized("queue.mode"), "Playback Mode")
        XCTAssertEqual(
            controller.localized("queue.mode.ordered"),
            "Repeat in Order"
        )
        XCTAssertEqual(
            controller.localized("queue.mode.shuffled"),
            "Repeat in Shuffle"
        )
        XCTAssertEqual(
            controller.localized("queue.mode.repeatCurrent"),
            "Repeat Current Video"
        )
        XCTAssertEqual(
            controller.localized("player.desktop.addTemporary"),
            "Add and Set as Dynamic Desktop"
        )
        XCTAssertEqual(
            controller.localized("external.open.none"),
            "No supported video in this request could be played."
        )
        XCTAssertEqual(
            controller.localizedFormat("external.open.skipped", 2),
            "2 files could not be played and were skipped."
        )
        XCTAssertEqual(
            controller.localizedFormat("external.open.skipped.one", 1),
            "1 file could not be played and was skipped."
        )
        XCTAssertEqual(
            controller.localized("external.open.restoreDynamicDesktop"),
            "Restore Dynamic Desktop"
        )
        controller.selectLanguage(.simplifiedChinese)

        XCTAssertEqual(controller.localized("queue.hide"), "隐藏播放队列")
        XCTAssertEqual(
            controller.localized("queue.navigation"),
            "媒体库或播放队列"
        )
        XCTAssertEqual(controller.localized("queue.empty"), "播放队列为空")
        XCTAssertEqual(
            controller.localized("queue.empty.detail"),
            "从媒体库播放视频，或在访达中打开视频。"
        )
        XCTAssertEqual(
            controller.localizedFormat("queue.upNext.count", 3),
            "待播放 3 个"
        )
        XCTAssertEqual(controller.localized("queue.mode"), "播放模式")
        XCTAssertEqual(
            controller.localized("queue.mode.ordered"),
            "顺序循环"
        )
        XCTAssertEqual(
            controller.localized("queue.mode.shuffled"),
            "随机循环"
        )
        XCTAssertEqual(
            controller.localized("queue.mode.repeatCurrent"),
            "循环当前视频"
        )
        XCTAssertEqual(
            controller.localized("player.desktop.addTemporary"),
            "添加并设为动态桌面"
        )
        XCTAssertEqual(
            controller.localized("external.open.none"),
            "此次打开的文件中没有可播放的受支持视频。"
        )
        XCTAssertEqual(
            controller.localizedFormat("external.open.skipped", 2),
            "已跳过 2 个无法播放的文件。"
        )
        XCTAssertEqual(
            controller.localizedFormat("external.open.skipped.one", 1),
            "已跳过 1 个无法播放的文件。"
        )
        XCTAssertEqual(
            controller.localized("external.open.restoreDynamicDesktop"),
            "恢复动态桌面"
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
