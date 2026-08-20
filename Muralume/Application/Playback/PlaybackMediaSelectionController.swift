import Combine
import Foundation

@MainActor
final class PlaybackMediaSelectionController: ObservableObject {
    @Published private(set) var state: PlaybackMediaSelectionState = .empty
    @Published private(set) var hasCurrentMedia = false

    let externalSubtitles: ExternalSubtitleController

    private let engine: any PlaybackEngine
    private var savedPlayerSubtitleSelection: PlaybackSubtitleSelection?
    private var savedExternalSubtitleSelection: PlaybackSubtitleSelection?

    init(
        engine: any PlaybackEngine,
        externalSubtitleParser: (any SubtitleFileParsing)? = nil,
        externalSubtitleDiscovery:
            (any ExternalSubtitleDiscovering)? = nil,
        externalSubtitleAssociationStore:
            (any ExternalSubtitleAssociationStoring)? = nil
    ) {
        self.engine = engine
        externalSubtitles = ExternalSubtitleController(
            engine: engine,
            parser: externalSubtitleParser,
            discovery: externalSubtitleDiscovery,
            associationStore: externalSubtitleAssociationStore
        )
    }

    func refresh() {
        state = engine.currentMediaSelectionState()
    }

    func reset() {
        externalSubtitles.reset()
        savedPlayerSubtitleSelection = nil
        savedExternalSubtitleSelection = nil
        hasCurrentMedia = false
        state = .empty
    }

    func selectAudio(_ selection: PlaybackAudioSelection) {
        state = engine.selectAudio(selection)
    }

    func selectSubtitles(_ selection: PlaybackSubtitleSelection) {
        if externalSubtitles.track != nil || externalSubtitles.isLoading {
            externalSubtitles.clear(removeRememberedAssociation: true)
            savedExternalSubtitleSelection = nil
        }
        state = engine.selectSubtitles(selection)
    }

    func prepareExternalSubtitles(for mediaURL: URL) {
        hasCurrentMedia = true
        externalSubtitles.prepare(for: mediaURL) { [weak self] in
            self?.activateExternalSubtitles()
        }
    }

    func loadExternalSubtitle(_ subtitleURL: URL, for mediaURL: URL) {
        externalSubtitles.loadUserSelected(
            subtitleURL,
            for: mediaURL
        ) { [weak self] in
            self?.activateExternalSubtitles()
        }
    }

    func removeExternalSubtitles() {
        guard externalSubtitles.track != nil
                || externalSubtitles.isLoading else {
            return
        }
        externalSubtitles.clear(removeRememberedAssociation: true)
        restoreSelectionAfterExternalSubtitles()
    }

    func suppressSubtitlesForDesktop() {
        guard savedPlayerSubtitleSelection == nil,
              externalSubtitles.track == nil,
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
        if externalSubtitles.track != nil {
            savedExternalSubtitleSelection = savedPlayerSubtitleSelection
            return
        }
        state = engine.selectSubtitles(savedPlayerSubtitleSelection)
    }

    private func activateExternalSubtitles() {
        if savedExternalSubtitleSelection == nil {
            savedExternalSubtitleSelection =
                savedPlayerSubtitleSelection ?? state.subtitleSelection
        }
        state = engine.selectSubtitles(.off)
    }

    private func restoreSelectionAfterExternalSubtitles() {
        guard let savedExternalSubtitleSelection else {
            return
        }
        self.savedExternalSubtitleSelection = nil
        if savedPlayerSubtitleSelection != nil {
            savedPlayerSubtitleSelection = savedExternalSubtitleSelection
        } else {
            state = engine.selectSubtitles(savedExternalSubtitleSelection)
        }
    }
}
