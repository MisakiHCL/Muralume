import Foundation
import XCTest
@testable import Muralume

final class SubtitleFileParserTests: XCTestCase {
    func testParsesSRTAndSanitizesSupportedMarkup() throws {
        let url = try makeTemporaryFile(
            extension: "srt",
            content: """
            1
            00:00:01,000 --> 00:00:03,250
            <i>Hello</i><br>world &amp; friends

            2
            00:00:03,250 --> 00:00:04,000
            Goodbye
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let timeline = try SubtitleFileParser().parse(url)

        XCTAssertEqual(timeline.cues.count, 2)
        XCTAssertNil(timeline.text(at: 0.99))
        XCTAssertEqual(timeline.text(at: 1), "Hello\nworld & friends")
        XCTAssertEqual(timeline.text(at: 3.5), "Goodbye")
        XCTAssertNil(timeline.text(at: 4))
    }

    func testParsesWebVTTIdentifiersAndCueSettings() throws {
        let url = try makeTemporaryFile(
            extension: "vtt",
            content: """
            WEBVTT

            intro
            00:01.500 --> 00:03.000 align:middle
            First cue

            00:00:04.000 --> 00:00:05.000
            Second cue
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let timeline = try SubtitleFileParser().parse(url)

        XCTAssertEqual(timeline.cues.count, 2)
        XCTAssertEqual(timeline.text(at: 2), "First cue")
        XCTAssertEqual(timeline.text(at: 4.5), "Second cue")
    }

    func testRejectsInvalidTiming() throws {
        let url = try makeTemporaryFile(
            extension: "srt",
            content: "1\n00:00:03,000 --> 00:00:01,000\nInvalid"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try SubtitleFileParser().parse(url)) { error in
            XCTAssertEqual(
                error as? ExternalSubtitleLoadFailure,
                .invalidFormat
            )
        }
    }

    private func makeTemporaryFile(
        extension fileExtension: String,
        content: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}

final class SubtitleTimelineTests: XCTestCase {
    func testCombinesOverlappingCuesInSourceOrder() {
        let timeline = SubtitleTimeline(
            cues: [
                SubtitleCue(startTime: 1, endTime: 5, text: "First"),
                SubtitleCue(startTime: 2, endTime: 3, text: "Second")
            ]
        )

        XCTAssertEqual(timeline.text(at: 2.5), "First\nSecond")
        XCTAssertEqual(timeline.text(at: 4), "First")
    }
}

final class SubtitleSidecarDiscoveryTests: XCTestCase {
    func testPrefersExactSidecarThenPreferredLanguage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("Movie.mp4")
        let exactURL = directory.appendingPathComponent("Movie.srt")
        let chineseURL = directory.appendingPathComponent("Movie.zh-Hans.vtt")
        let englishURL = directory.appendingPathComponent("Movie.en.srt")
        try Data().write(to: mediaURL)
        try Data().write(to: chineseURL)
        try Data().write(to: englishURL)
        try Data().write(to: exactURL)

        let discovery = SubtitleSidecarDiscovery()
        XCTAssertEqual(
            discovery.discover(
                for: mediaURL,
                preferredLanguageCodes: ["zh-Hans"]
            )?.standardizedFileURL,
            exactURL.standardizedFileURL
        )

        try FileManager.default.removeItem(at: exactURL)
        XCTAssertEqual(
            discovery.discover(
                for: mediaURL,
                preferredLanguageCodes: ["zh-Hans"]
            )?.standardizedFileURL,
            chineseURL.standardizedFileURL
        )
    }
}

@MainActor
final class ExternalSubtitleControllerTests: XCTestCase {
    func testExternalSubtitleSuppressesAndRestoresEmbeddedSelection() async throws {
        let subtitleURL = try makeTemporarySubtitle()
        defer { try? FileManager.default.removeItem(at: subtitleURL) }
        let mediaURL = URL(fileURLWithPath: "/tmp/video.mp4")
        let engine = TestPlaybackEngine()
        engine.mediaSelectionState = makeMediaSelectionState()
        let controller = PlaybackMediaSelectionController(
            engine: engine,
            externalSubtitleParser: SubtitleFileParser()
        )
        controller.refresh()
        controller.prepareExternalSubtitles(for: mediaURL)

        controller.loadExternalSubtitle(subtitleURL, for: mediaURL)
        await waitUntil { controller.externalSubtitles.track != nil }

        XCTAssertEqual(controller.state.subtitleSelection, .off)
        XCTAssertEqual(engine.subtitleSelections.last, .off)

        engine.publishExternalSubtitleTime(1.5)
        XCTAssertEqual(controller.externalSubtitles.cueText, "External cue")

        controller.suppressSubtitlesForDesktop()
        controller.restorePlayerSubtitleSelection()
        XCTAssertNotNil(controller.externalSubtitles.track)
        XCTAssertEqual(controller.state.subtitleSelection, .off)

        controller.removeExternalSubtitles()

        XCTAssertNil(controller.externalSubtitles.track)
        XCTAssertNil(engine.externalSubtitleTimeHandler)
        XCTAssertEqual(controller.state.subtitleSelection, .automatic)
        XCTAssertEqual(engine.subtitleSelections.last, .automatic)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for external subtitle load")
    }

    private func makeTemporarySubtitle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("srt")
        try Data(
            "1\n00:00:01,000 --> 00:00:02,000\nExternal cue".utf8
        ).write(to: url, options: .atomic)
        return url
    }

    private func makeMediaSelectionState() -> PlaybackMediaSelectionState {
        let subtitle = PlaybackMediaOption(
            id: PlaybackMediaOptionID(rawValue: "subtitle-0"),
            displayName: "English",
            languageIdentifier: "en",
            characteristics: []
        )
        return PlaybackMediaSelectionState(
            audioOptions: [],
            subtitleOptions: [subtitle],
            audioSelection: .automatic,
            subtitleSelection: .automatic,
            effectiveAudioOptionID: nil,
            effectiveSubtitleOptionID: nil,
            allowsEmptySubtitleSelection: true
        )
    }
}
