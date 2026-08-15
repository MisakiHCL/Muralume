import CoreFoundation
import Foundation

enum AppPreferencesStorageKey {
    static let volume = "settings.playback.volume"
    static let isMuted = "settings.playback.is-muted"
    static let restorableVolume = "settings.playback.restorable-volume"
    static let playbackRate = "settings.playback.rate"
    static let playbackOrder = "settings.playback.order"
    static let playbackRepeatBehavior = "settings.playback.repeat-behavior"
    static let librarySortField = "settings.library.sort-field"
    static let librarySortDirection = "settings.library.sort-direction"
    // Keep the existing key so current installations retain their language.
    static let language = "settings.app-language"
    static let smartPauseEnabled = "settings.smart-pause.enabled"
    static let smartPauseDesktopHidden =
        "settings.smart-pause.desktop-hidden"
    static let smartPauseLowPowerMode =
        "settings.smart-pause.low-power-mode"
    static let smartPauseLimitedPowerSource =
        "settings.smart-pause.limited-power-source"
    static let smartPauseSustainedSystemLoad =
        "settings.smart-pause.sustained-system-load"
}

private struct UserDefaultsAppPreferencesDTO {
    let volume: Float?
    let isMuted: Bool?
    let restorableVolume: Float?
    let playbackRate: Float?
    let playbackOrder: String?
    let playbackRepeatBehavior: String?
    let librarySortField: String?
    let librarySortDirection: String?
    let language: String?
    let smartPauseEnabled: Bool?
    let smartPauseDesktopHidden: Bool?
    let smartPauseLowPowerMode: Bool?
    let smartPauseLimitedPowerSource: Bool?
    let smartPauseSustainedSystemLoad: Bool?

    init(userDefaults: UserDefaults) {
        volume = Self.float(
            userDefaults,
            forKey: AppPreferencesStorageKey.volume
        )
        isMuted = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.isMuted
        )
        restorableVolume = Self.float(
            userDefaults,
            forKey: AppPreferencesStorageKey.restorableVolume
        )
        playbackRate = Self.float(
            userDefaults,
            forKey: AppPreferencesStorageKey.playbackRate
        )
        playbackOrder = userDefaults.string(
            forKey: AppPreferencesStorageKey.playbackOrder
        )
        playbackRepeatBehavior = userDefaults.string(
            forKey: AppPreferencesStorageKey.playbackRepeatBehavior
        )
        librarySortField = userDefaults.string(
            forKey: AppPreferencesStorageKey.librarySortField
        )
        librarySortDirection = userDefaults.string(
            forKey: AppPreferencesStorageKey.librarySortDirection
        )
        language = userDefaults.string(
            forKey: AppPreferencesStorageKey.language
        )
        smartPauseEnabled = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.smartPauseEnabled
        )
        smartPauseDesktopHidden = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.smartPauseDesktopHidden
        )
        smartPauseLowPowerMode = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.smartPauseLowPowerMode
        )
        smartPauseLimitedPowerSource = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.smartPauseLimitedPowerSource
        )
        smartPauseSustainedSystemLoad = Self.bool(
            userDefaults,
            forKey: AppPreferencesStorageKey.smartPauseSustainedSystemLoad
        )
    }

    private static func float(
        _ userDefaults: UserDefaults,
        forKey key: String
    ) -> Float? {
        guard let number = userDefaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.floatValue
    }

    private static func bool(
        _ userDefaults: UserDefaults,
        forKey key: String
    ) -> Bool? {
        guard let number = userDefaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}

@MainActor
final class UserDefaultsAppPreferencesStore: AppPreferencesStoring {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> AppPreferences {
        let defaults = AppPreferences.defaultValue
        let stored = UserDefaultsAppPreferencesDTO(
            userDefaults: userDefaults
        )
        let storedVolume = validFloat(
            stored.volume,
            in: 0...1
        ).map(PlaybackVolume.init(rawValue:))
            ?? defaults.audio.volume
        let isMuted = stored.isMuted ?? defaults.audio.isMuted
        let restorableVolume = validFloat(
            stored.restorableVolume,
            in: Float.leastNonzeroMagnitude...1
        ).map(PlaybackVolume.init(rawValue:))
            ?? (
                storedVolume == .muted
                    ? defaults.audio.restorableVolume
                    : storedVolume
            )

        return AppPreferences(
            audio: PlaybackAudioPreferences(
                volume: storedVolume,
                isMuted: isMuted,
                restorableVolume: restorableVolume
            ),
            playbackRate: loadPlaybackRate(
                stored.playbackRate,
                defaultValue: defaults.playbackRate
            ),
            playbackOrder: loadRawRepresentable(
                stored.playbackOrder,
                PlaybackOrder.self
            ) ?? defaults.playbackOrder,
            playbackRepeatBehavior: loadRawRepresentable(
                stored.playbackRepeatBehavior,
                PlaybackRepeatBehavior.self
            ) ?? defaults.playbackRepeatBehavior,
            librarySort: MediaLibrarySort(
                field: loadRawRepresentable(
                    stored.librarySortField,
                    MediaLibrarySortField.self
                ) ?? defaults.librarySort.field,
                direction: loadRawRepresentable(
                    stored.librarySortDirection,
                    MediaLibrarySortDirection.self
                ) ?? defaults.librarySort.direction
            ),
            language: loadRawRepresentable(
                stored.language,
                AppLanguage.self
            ) ?? defaults.language,
            smartPause: SmartPausePreferences(
                isEnabled: stored.smartPauseEnabled
                    ?? defaults.smartPause.isEnabled,
                pauseWhenDesktopHidden: stored.smartPauseDesktopHidden
                    ?? defaults.smartPause.pauseWhenDesktopHidden,
                pauseInLowPowerMode: stored.smartPauseLowPowerMode
                    ?? defaults.smartPause.pauseInLowPowerMode,
                pauseOnLimitedPowerSource:
                    stored.smartPauseLimitedPowerSource
                    ?? defaults.smartPause.pauseOnLimitedPowerSource,
                pauseUnderSustainedSystemLoad:
                    stored.smartPauseSustainedSystemLoad
                    ?? defaults.smartPause.pauseUnderSustainedSystemLoad
            )
        )
    }

    func saveAudio(_ audio: PlaybackAudioPreferences) {
        userDefaults.set(
            audio.restorableVolume.rawValue,
            forKey: AppPreferencesStorageKey.restorableVolume
        )
        userDefaults.set(
            audio.volume.rawValue,
            forKey: AppPreferencesStorageKey.volume
        )
        userDefaults.set(
            audio.isMuted,
            forKey: AppPreferencesStorageKey.isMuted
        )
    }

    func savePlaybackRate(_ rate: PlaybackRate) {
        userDefaults.set(
            rate.rawValue,
            forKey: AppPreferencesStorageKey.playbackRate
        )
    }

    func savePlaybackOrder(_ order: PlaybackOrder) {
        userDefaults.set(
            order.rawValue,
            forKey: AppPreferencesStorageKey.playbackOrder
        )
    }

    func savePlaybackRepeatBehavior(
        _ behavior: PlaybackRepeatBehavior
    ) {
        userDefaults.set(
            behavior.rawValue,
            forKey: AppPreferencesStorageKey.playbackRepeatBehavior
        )
    }

    func saveLibrarySort(_ sort: MediaLibrarySort) {
        userDefaults.set(
            sort.field.rawValue,
            forKey: AppPreferencesStorageKey.librarySortField
        )
        userDefaults.set(
            sort.direction.rawValue,
            forKey: AppPreferencesStorageKey.librarySortDirection
        )
    }

    func saveLanguage(_ language: AppLanguage) {
        userDefaults.set(
            language.rawValue,
            forKey: AppPreferencesStorageKey.language
        )
    }

    func saveSmartPause(_ preferences: SmartPausePreferences) {
        userDefaults.set(
            preferences.isEnabled,
            forKey: AppPreferencesStorageKey.smartPauseEnabled
        )
        userDefaults.set(
            preferences.pauseWhenDesktopHidden,
            forKey: AppPreferencesStorageKey.smartPauseDesktopHidden
        )
        userDefaults.set(
            preferences.pauseInLowPowerMode,
            forKey: AppPreferencesStorageKey.smartPauseLowPowerMode
        )
        userDefaults.set(
            preferences.pauseOnLimitedPowerSource,
            forKey: AppPreferencesStorageKey.smartPauseLimitedPowerSource
        )
        userDefaults.set(
            preferences.pauseUnderSustainedSystemLoad,
            forKey: AppPreferencesStorageKey.smartPauseSustainedSystemLoad
        )
    }

    private func loadPlaybackRate(
        _ storedValue: Float?,
        defaultValue: PlaybackRate
    ) -> PlaybackRate {
        guard let rawValue = validFloat(
            storedValue,
            in: 0.25...2
        ) else {
            return defaultValue
        }

        let rate = PlaybackRate(rawValue: rawValue)
        return PlaybackPolicy.supportedRates.contains(rate)
            ? rate
            : defaultValue
    }

    private func validFloat(
        _ storedValue: Float?,
        in range: ClosedRange<Float>
    ) -> Float? {
        guard let value = storedValue else {
            return nil
        }
        guard value.isFinite, range.contains(value) else {
            return nil
        }
        return value
    }

    private func loadRawRepresentable<Value>(
        _ rawValue: String?,
        _ type: Value.Type
    ) -> Value? where Value: RawRepresentable, Value.RawValue == String {
        guard let rawValue else {
            return nil
        }
        return type.init(rawValue: rawValue)
    }
}
