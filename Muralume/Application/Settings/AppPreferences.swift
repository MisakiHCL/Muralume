import Combine
import Foundation

struct SmartPausePreferences: Equatable, Sendable {
    static let defaultValue = SmartPausePreferences(
        isEnabled: true,
        pauseWhenDesktopHidden: true,
        pauseInLowPowerMode: true,
        pauseOnLimitedPowerSource: false,
        pauseUnderSustainedSystemLoad: false
    )

    var isEnabled: Bool
    var pauseWhenDesktopHidden: Bool
    var pauseInLowPowerMode: Bool
    var pauseOnLimitedPowerSource: Bool
    var pauseUnderSustainedSystemLoad: Bool
}

struct PlaybackAudioPreferences: Equatable, Sendable {
    static let defaultValue = PlaybackAudioPreferences(
        volume: .full,
        isMuted: false,
        restorableVolume: .full
    )

    let volume: PlaybackVolume
    let isMuted: Bool
    let restorableVolume: PlaybackVolume

    init(
        volume: PlaybackVolume,
        isMuted: Bool,
        restorableVolume: PlaybackVolume
    ) {
        self.volume = isMuted ? .muted : volume
        self.isMuted = isMuted

        if !isMuted, volume != .muted {
            self.restorableVolume = volume
        } else if restorableVolume != .muted {
            self.restorableVolume = restorableVolume
        } else {
            self.restorableVolume = .full
        }
    }
}

struct AppPreferences: Equatable, Sendable {
    static let defaultValue = AppPreferences(
        audio: .defaultValue,
        playbackRate: PlaybackPolicy.defaultRate,
        playbackOrder: .shuffled,
        playbackRepeatBehavior: .queue,
        librarySort: MediaLibrarySort(),
        language: .system,
        subtitleAppearance: .defaultValue,
        smartPause: .defaultValue
    )

    let audio: PlaybackAudioPreferences
    let playbackRate: PlaybackRate
    let playbackOrder: PlaybackOrder
    let playbackRepeatBehavior: PlaybackRepeatBehavior
    let librarySort: MediaLibrarySort
    let language: AppLanguage
    let subtitleAppearance: SubtitleAppearancePreferences
    let smartPause: SmartPausePreferences

    init(
        audio: PlaybackAudioPreferences,
        playbackRate: PlaybackRate,
        playbackOrder: PlaybackOrder,
        playbackRepeatBehavior: PlaybackRepeatBehavior,
        librarySort: MediaLibrarySort,
        language: AppLanguage,
        subtitleAppearance: SubtitleAppearancePreferences = .defaultValue,
        smartPause: SmartPausePreferences = .defaultValue
    ) {
        self.audio = audio
        self.playbackRate = playbackRate
        self.playbackOrder = playbackOrder
        self.playbackRepeatBehavior = playbackRepeatBehavior
        self.librarySort = librarySort
        self.language = language
        self.subtitleAppearance = subtitleAppearance
        self.smartPause = smartPause
    }
}

@MainActor
protocol AppPreferencesStoring: AnyObject {
    func load() -> AppPreferences
    func saveAudio(_ audio: PlaybackAudioPreferences)
    func savePlaybackRate(_ rate: PlaybackRate)
    func savePlaybackOrder(_ order: PlaybackOrder)
    func savePlaybackRepeatBehavior(_ behavior: PlaybackRepeatBehavior)
    func saveLibrarySort(_ sort: MediaLibrarySort)
    func saveLanguage(_ language: AppLanguage)
    func saveSubtitleAppearance(_ preferences: SubtitleAppearancePreferences)
    func saveSmartPause(_ preferences: SmartPausePreferences)
}

@MainActor
final class SmartPauseController: ObservableObject {
    @Published private(set) var preferences: SmartPausePreferences

    var preferencesDidChangeHandler: ((SmartPausePreferences) -> Void)?

    private let store: (any AppPreferencesStoring)?

    init(
        preferences: SmartPausePreferences = .defaultValue,
        store: (any AppPreferencesStoring)? = nil
    ) {
        self.preferences = preferences
        self.store = store
    }

    func setEnabled(_ isEnabled: Bool) {
        update { $0.isEnabled = isEnabled }
    }

    func setPauseWhenDesktopHidden(_ isEnabled: Bool) {
        update { $0.pauseWhenDesktopHidden = isEnabled }
    }

    func setPauseInLowPowerMode(_ isEnabled: Bool) {
        update { $0.pauseInLowPowerMode = isEnabled }
    }

    func setPauseOnLimitedPowerSource(_ isEnabled: Bool) {
        update { $0.pauseOnLimitedPowerSource = isEnabled }
    }

    func setPauseUnderSustainedSystemLoad(_ isEnabled: Bool) {
        update { $0.pauseUnderSustainedSystemLoad = isEnabled }
    }

    private func update(
        _ mutation: (inout SmartPausePreferences) -> Void
    ) {
        var updatedPreferences = preferences
        mutation(&updatedPreferences)
        guard updatedPreferences != preferences else {
            return
        }
        preferences = updatedPreferences
        store?.saveSmartPause(updatedPreferences)
        preferencesDidChangeHandler?(updatedPreferences)
    }
}
