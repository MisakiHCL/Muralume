import XCTest
@testable import Muralume

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    private enum TestStorage {
        static let suiteName = "com.muralume.tests.preferences"
    }

    func testMissingValuesUseCentralDefaults() throws {
        try withStore { store, _ in
            let preferences = store.load()

            XCTAssertEqual(preferences, .defaultValue)
            XCTAssertEqual(preferences.playbackOrder, .shuffled)
            XCTAssertEqual(preferences.playbackRepeatBehavior, .queue)
        }
    }

    func testEveryPreferencePersistsAcrossStoreInstances() throws {
        try withStore { store, defaults in
            let audio = PlaybackAudioPreferences(
                volume: .muted,
                isMuted: true,
                restorableVolume: PlaybackVolume(rawValue: 0.4)
            )
            let sort = MediaLibrarySort(
                field: .fileSize,
                direction: .descending
            )
            let smartPause = SmartPausePreferences(
                isEnabled: false,
                pauseWhenDesktopHidden: false,
                pauseInLowPowerMode: false,
                pauseOnLimitedPowerSource: true,
                pauseUnderSustainedSystemLoad: true
            )

            store.saveAudio(audio)
            store.savePlaybackRate(PlaybackRate(rawValue: 1.5))
            store.savePlaybackOrder(.ordered)
            store.savePlaybackRepeatBehavior(.currentItem)
            store.saveLibrarySort(sort)
            store.saveLanguage(.simplifiedChinese)
            store.saveSmartPause(smartPause)

            let restored = UserDefaultsAppPreferencesStore(
                userDefaults: defaults
            ).load()

            XCTAssertEqual(restored.audio, audio)
            XCTAssertEqual(
                restored.playbackRate,
                PlaybackRate(rawValue: 1.5)
            )
            XCTAssertEqual(restored.playbackOrder, .ordered)
            XCTAssertEqual(
                restored.playbackRepeatBehavior,
                .currentItem
            )
            XCTAssertEqual(restored.librarySort, sort)
            XCTAssertEqual(restored.language, .simplifiedChinese)
            XCTAssertEqual(restored.smartPause, smartPause)
            XCTAssertEqual(
                defaults.string(
                    forKey: AppPreferencesStorageKey.language
                ),
                "zh-Hans"
            )
        }
    }

    func testInvalidValuesFallBackPerFieldWithoutDiscardingValidFields() throws {
        try withStore { store, defaults in
            defaults.set(
                Float.nan,
                forKey: AppPreferencesStorageKey.volume
            )
            defaults.set(
                "invalid",
                forKey: AppPreferencesStorageKey.isMuted
            )
            defaults.set(
                -0.5,
                forKey: AppPreferencesStorageKey.restorableVolume
            )
            defaults.set(
                1.3,
                forKey: AppPreferencesStorageKey.playbackRate
            )
            defaults.set(
                "invalid",
                forKey: AppPreferencesStorageKey.playbackOrder
            )
            defaults.set(
                "invalid",
                forKey: AppPreferencesStorageKey.playbackRepeatBehavior
            )
            defaults.set(
                MediaLibrarySortField.fileSize.rawValue,
                forKey: AppPreferencesStorageKey.librarySortField
            )
            defaults.set(
                "invalid",
                forKey: AppPreferencesStorageKey.librarySortDirection
            )
            defaults.set(
                "unsupported",
                forKey: AppPreferencesStorageKey.language
            )
            defaults.set(
                "invalid",
                forKey: AppPreferencesStorageKey.smartPauseEnabled
            )
            defaults.set(
                false,
                forKey: AppPreferencesStorageKey.smartPauseDesktopHidden
            )
            defaults.set(
                true,
                forKey: AppPreferencesStorageKey.smartPauseLimitedPowerSource
            )

            let restored = store.load()

            XCTAssertEqual(restored.audio, .defaultValue)
            XCTAssertEqual(
                restored.playbackRate,
                PlaybackPolicy.defaultRate
            )
            XCTAssertEqual(restored.playbackOrder, .shuffled)
            XCTAssertEqual(restored.playbackRepeatBehavior, .queue)
            XCTAssertEqual(restored.librarySort.field, .fileSize)
            XCTAssertEqual(restored.librarySort.direction, .ascending)
            XCTAssertEqual(restored.language, .system)
            XCTAssertTrue(restored.smartPause.isEnabled)
            XCTAssertFalse(restored.smartPause.pauseWhenDesktopHidden)
            XCTAssertTrue(restored.smartPause.pauseInLowPowerMode)
            XCTAssertTrue(restored.smartPause.pauseOnLimitedPowerSource)
            XCTAssertFalse(
                restored.smartPause.pauseUnderSustainedSystemLoad
            )
        }
    }

    func testDisablingSmartPausePreservesOptionsAndNotifiesSession() {
        let store = TestAppPreferencesStore()
        let controller = SmartPauseController(store: store)
        var observedPreferences: [SmartPausePreferences] = []
        controller.preferencesDidChangeHandler = {
            observedPreferences.append($0)
        }

        controller.setPauseOnLimitedPowerSource(true)
        controller.setEnabled(false)
        controller.setEnabled(true)

        XCTAssertTrue(
            controller.preferences.pauseOnLimitedPowerSource
        )
        XCTAssertEqual(
            observedPreferences,
            store.savedSmartPausePreferences
        )
        XCTAssertEqual(observedPreferences.count, 3)
    }

    func testBooleanAndNumericTypesAreNotCoercedAcrossPreferenceFields() throws {
        try withStore { store, defaults in
            defaults.set(
                false,
                forKey: AppPreferencesStorageKey.volume
            )
            defaults.set(
                NSNumber(value: 1),
                forKey: AppPreferencesStorageKey.isMuted
            )

            let restored = store.load()

            XCTAssertEqual(restored.audio.volume, .full)
            XCTAssertFalse(restored.audio.isMuted)
        }
    }

    func testLegacyLanguageKeyIsReadWithoutMigration() throws {
        try withStore { store, defaults in
            defaults.set(
                AppLanguage.english.rawValue,
                forKey: "settings.app-language"
            )

            XCTAssertEqual(store.load().language, .english)
            XCTAssertEqual(
                AppPreferencesStorageKey.language,
                "settings.app-language"
            )
        }
    }

    private func withStore(
        _ test: (
            UserDefaultsAppPreferencesStore,
            UserDefaults
        ) throws -> Void
    ) throws {
        let suiteName = TestStorage.suiteName
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        try test(
            UserDefaultsAppPreferencesStore(userDefaults: defaults),
            defaults
        )
    }
}
