import Foundation

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
        language: .system
    )

    let audio: PlaybackAudioPreferences
    let playbackRate: PlaybackRate
    let playbackOrder: PlaybackOrder
    let playbackRepeatBehavior: PlaybackRepeatBehavior
    let librarySort: MediaLibrarySort
    let language: AppLanguage
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
}
