import XCTest
@testable import Muralume

@MainActor
final class PlaybackMediaSelectionControllerTests: XCTestCase {
    func testCoordinatorRefreshesAndRestoresSelectionAcrossDesktop() async throws {
        let engine = TestPlaybackEngine()
        engine.mediaSelectionState = makeState()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        coordinator.registerPlayerSurface(playerSurface)
        let result = await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/tracks.mp4"),
                displayName: "Tracks"
            )
        )
        let subtitleID = try XCTUnwrap(
            coordinator.mediaSelection.state.subtitleOptions.first?.id
        )
        coordinator.mediaSelection.selectSubtitles(.option(subtitleID))

        try await coordinator.transitionToDesktop(
            TestPlaybackSurface(id: .desktop)
        )

        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(
            coordinator.mediaSelection.state.subtitleSelection,
            .off
        )

        try await coordinator.transitionToPlayer()

        XCTAssertEqual(
            coordinator.mediaSelection.state.subtitleSelection,
            .option(subtitleID)
        )
    }

    func testRefreshAndExplicitSelectionsPublishEngineState() {
        let engine = TestPlaybackEngine()
        engine.mediaSelectionState = makeState()
        let controller = PlaybackMediaSelectionController(engine: engine)
        let spanishAudioID = engine.mediaSelectionState.audioOptions[1].id
        let englishSubtitleID = engine.mediaSelectionState
            .subtitleOptions[0].id

        controller.refresh()
        controller.selectAudio(.option(spanishAudioID))
        controller.selectSubtitles(.option(englishSubtitleID))

        XCTAssertEqual(
            controller.state.audioSelection,
            .option(spanishAudioID)
        )
        XCTAssertEqual(
            controller.state.subtitleSelection,
            .option(englishSubtitleID)
        )
        XCTAssertEqual(controller.state.effectiveAudioOptionID, spanishAudioID)
        XCTAssertEqual(
            controller.state.effectiveSubtitleOptionID,
            englishSubtitleID
        )
    }

    func testDesktopSuppressionRestoresPlayerSubtitleSelection() {
        let engine = TestPlaybackEngine()
        engine.mediaSelectionState = makeState()
        let subtitleID = engine.mediaSelectionState.subtitleOptions[0].id
        let controller = PlaybackMediaSelectionController(engine: engine)
        controller.refresh()
        controller.selectSubtitles(.option(subtitleID))

        controller.suppressSubtitlesForDesktop()

        XCTAssertEqual(controller.state.subtitleSelection, .off)
        XCTAssertEqual(engine.subtitleSelections.last, .off)

        controller.restorePlayerSubtitleSelection()

        XCTAssertEqual(controller.state.subtitleSelection, .option(subtitleID))
        XCTAssertEqual(
            engine.subtitleSelections,
            [.option(subtitleID), .off, .option(subtitleID)]
        )
    }

    func testSuppressionIsIdempotentAndResetDropsPendingRestore() {
        let engine = TestPlaybackEngine()
        engine.mediaSelectionState = makeState()
        let controller = PlaybackMediaSelectionController(engine: engine)
        controller.refresh()

        controller.suppressSubtitlesForDesktop()
        controller.suppressSubtitlesForDesktop()
        controller.reset()
        controller.restorePlayerSubtitleSelection()

        XCTAssertEqual(engine.subtitleSelections, [.off])
        XCTAssertEqual(controller.state, .empty)
    }

    func testControlsAppearOnlyForUsefulAlternatives() {
        let singleAudio = PlaybackMediaSelectionState(
            audioOptions: [makeOption(id: "audio-0", name: "English")],
            subtitleOptions: [],
            audioSelection: .automatic,
            subtitleSelection: .automatic,
            effectiveAudioOptionID: nil,
            effectiveSubtitleOptionID: nil,
            allowsEmptySubtitleSelection: true
        )
        let withSubtitles = PlaybackMediaSelectionState(
            audioOptions: singleAudio.audioOptions,
            subtitleOptions: [
                makeOption(id: "subtitle-0", name: "English")
            ],
            audioSelection: singleAudio.audioSelection,
            subtitleSelection: singleAudio.subtitleSelection,
            effectiveAudioOptionID: nil,
            effectiveSubtitleOptionID: nil,
            allowsEmptySubtitleSelection: true
        )

        XCTAssertFalse(PlaybackMediaSelectionState.empty.showsTrackControls)
        XCTAssertFalse(singleAudio.showsTrackControls)
        XCTAssertTrue(withSubtitles.showsTrackControls)
        XCTAssertTrue(makeState().showsTrackControls)
    }

    private func makeState() -> PlaybackMediaSelectionState {
        let firstAudio = makeOption(id: "audio-0", name: "English")
        let secondAudio = makeOption(id: "audio-1", name: "Español")
        let subtitle = makeOption(id: "subtitle-0", name: "English CC")
        return PlaybackMediaSelectionState(
            audioOptions: [firstAudio, secondAudio],
            subtitleOptions: [subtitle],
            audioSelection: .automatic,
            subtitleSelection: .automatic,
            effectiveAudioOptionID: firstAudio.id,
            effectiveSubtitleOptionID: nil,
            allowsEmptySubtitleSelection: true
        )
    }

    private func makeOption(
        id: String,
        name: String
    ) -> PlaybackMediaOption {
        PlaybackMediaOption(
            id: PlaybackMediaOptionID(rawValue: id),
            displayName: name,
            languageIdentifier: nil,
            characteristics: []
        )
    }
}
