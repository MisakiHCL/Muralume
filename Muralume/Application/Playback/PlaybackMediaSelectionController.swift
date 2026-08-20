import Combine

@MainActor
final class PlaybackMediaSelectionController: ObservableObject {
    @Published private(set) var state: PlaybackMediaSelectionState = .empty

    private let engine: any PlaybackEngine
    private var savedPlayerSubtitleSelection: PlaybackSubtitleSelection?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    func refresh() {
        state = engine.currentMediaSelectionState()
    }

    func reset() {
        savedPlayerSubtitleSelection = nil
        state = .empty
    }

    func selectAudio(_ selection: PlaybackAudioSelection) {
        state = engine.selectAudio(selection)
    }

    func selectSubtitles(_ selection: PlaybackSubtitleSelection) {
        state = engine.selectSubtitles(selection)
    }

    func suppressSubtitlesForDesktop() {
        guard savedPlayerSubtitleSelection == nil,
              !state.subtitleOptions.isEmpty else {
            return
        }
        savedPlayerSubtitleSelection = state.subtitleSelection
        state = engine.selectSubtitles(.off)
    }

    func restorePlayerSubtitleSelection() {
        guard let savedPlayerSubtitleSelection else {
            return
        }
        self.savedPlayerSubtitleSelection = nil
        state = engine.selectSubtitles(savedPlayerSubtitleSelection)
    }
}
