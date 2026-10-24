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

    func testSanitizerMatchesLegacyMarkupAndWhitespaceSemantics() throws {
        let tokens = [
            "plain", "<", ">", "<>", "<<>", "<i>", "</i>", "<br>",
            "<BR/>", "<Br \t/>", "<br\u{0085}>", "<br\u{00A0}>",
            "<br\u{2028}/>", "<br\u{200B}>", "<br/ >", "<broken", "\n",
            "&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&nbsp;",
            "中文", "e\u{0301}", "👩🏽‍💻", " \t"
        ]
        var seed: UInt64 = 0x51B71E
        for _ in 0..<2_000 {
            var input = ""
            for _ in 0..<24 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                input += tokens[Int(seed >> 32) % tokens.count]
            }
            XCTAssertEqual(
                try SubtitleTextSanitizer.sanitize(input),
                legacySanitize(input), input
            )
        }
    }

    func testSanitizesBeforeApplyingFinalCharacterLimit() throws {
        let raw = String(repeating: "<i></i>", count: 5_000)
            + "  " + String(repeating: "&amp;", count: 5_000)
        let url = try makeTemporaryFile(
            extension: "srt", content: "1\n00:00:01,000 --> 00:00:02,000\n" + raw
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let timeline = try SubtitleFileParser().parse(url)

        XCTAssertEqual(
            timeline.cues.first?.text,
            String(repeating: "&", count: ExternalSubtitlePolicy.maximumCueCharacters)
        )
    }

    func testLongUnterminatedMarkupDoesNotRescanEveryOpeningBracket() throws {
        let url = try makeTemporaryFile(
            extension: "srt",
            content: "1\n00:00:01,000 --> 00:00:02,000\n"
                + String(repeating: "<", count: 64 * 1_024)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let start = ContinuousClock.now

        let timeline = try SubtitleFileParser().parse(url)

        XCTAssertEqual(
            timeline.cues.first?.text,
            String(repeating: "<", count: ExternalSubtitlePolicy.maximumCueCharacters)
        )
        // The old quadratic expression takes about 25 seconds for this input.
        // This loose limit allows substantial CI variance for a linear scan.
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSanitizerHonorsTaskCancellation() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SubtitleTextSanitizer.sanitize(String(repeating: "<", count: 64 * 1_024))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled subtitle sanitization completed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func legacySanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression
        ).replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
    func testIntervalIndexAndCursorMatchNaiveQueriesAcrossSeeks() {
        var cues = [SubtitleCue(startTime: 0, endTime: 10_000, text: "Long")]
        for index in 0..<2_000 {
            let start = Double((index * 37) % 400) / 10
            cues.append(SubtitleCue(
                startTime: start, endTime: start + Double(index % 9 + 1) / 10,
                text: index % 17 == 0 ? "" : "Cue \(index)"
            ))
        }
        let timeline = SubtitleTimeline(cues: cues)
        var cursor = SubtitleTimelineCursor(timeline: timeline)
        let times = (0...410).map { Double($0) / 10 }
            + [0.1, 39.9, 0, 10_000, 9_999.9, 0.15]
        for time in times {
            let active = timeline.cues.filter { $0.startTime <= time && $0.endTime > time }
            let expected = active.isEmpty ? nil : active.map(\.text).joined(separator: "\n")
            XCTAssertEqual(timeline.text(at: time), expected, "At \(time)")
            XCTAssertEqual(cursor.text(at: time), expected, "Cursor at \(time)")
        }
    }

    func testCursorReusesTextUntilBoundaryAndRebuildsOnBackwardSeek() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(startTime: 1, endTime: 100, text: "Long"),
            SubtitleCue(startTime: 2, endTime: 3, text: "Short")
        ])
        var cursor = SubtitleTimelineCursor(timeline: timeline)
        XCTAssertEqual(cursor.text(at: 4), "Long")
        for index in 0..<100 { XCTAssertEqual(cursor.text(at: 4 + Double(index) / 20), "Long") }
        XCTAssertEqual(cursor.queryCount, 1)
        XCTAssertEqual(cursor.text(at: 2.5), "Long\nShort")
        XCTAssertEqual(cursor.queryCount, 2)
        XCTAssertEqual(cursor.text(at: 3), "Long")
        XCTAssertEqual(cursor.queryCount, 3)
        XCTAssertNil(cursor.text(at: 100))
        XCTAssertEqual(cursor.queryCount, 4)
        XCTAssertNil(cursor.text(at: .nan))
    }

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
    func testDiscoveryAndParsingShareOneWorkerAndKeepOnlyLatestPendingRequest() async {
        let work = BlockingSubtitleWork()
        defer { work.release() }
        let engine = TestPlaybackEngine()
        let controller = ExternalSubtitleController(engine: engine, parser: work, discovery: work)
        let firstMedia = URL(fileURLWithPath: "/tmp/first.mp4")
        let latestMedia = URL(fileURLWithPath: "/tmp/latest.mp4")
        let latestSubtitle = URL(fileURLWithPath: "/tmp/latest.srt")
        var activations = 0
        controller.prepare(for: firstMedia) { activations += 1 }
        await waitUntil { work.calls == ["discover:first.mp4"] }

        controller.loadUserSelected(URL(fileURLWithPath: "/tmp/stale.srt"), for: firstMedia) {
            activations += 1
        }
        controller.prepare(for: latestMedia) { activations += 1 }
        controller.loadUserSelected(latestSubtitle, for: latestMedia) { activations += 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(work.calls, ["discover:first.mp4"])

        work.release()
        await waitUntil { controller.track?.url == latestSubtitle }

        XCTAssertEqual(work.calls, ["discover:first.mp4", "parse:latest.srt"])
        XCTAssertEqual(work.maximumConcurrentCalls, 1)
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(controller.isLoading)
    }

    func testClearKeepsWorkerSlotUntilCancelledParserReallyReturns() async {
        let work = BlockingSubtitleWork()
        defer { work.release() }
        let engine = TestPlaybackEngine()
        let controller = ExternalSubtitleController(engine: engine, parser: work)
        let media = URL(fileURLWithPath: "/tmp/video.mp4")
        let firstSubtitle = URL(fileURLWithPath: "/tmp/first.srt")
        let lastSubtitle = URL(fileURLWithPath: "/tmp/last.srt")
        var staleActivations = 0
        controller.prepare(for: media) {}
        controller.loadUserSelected(firstSubtitle, for: media) { staleActivations += 1 }
        await waitUntil { work.calls == ["parse:first.srt"] }

        controller.clear(removeRememberedAssociation: false)
        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.track)
        for index in 0..<100 {
            controller.loadUserSelected(
                URL(fileURLWithPath: "/tmp/discarded-\(index).srt"), for: media
            ) { staleActivations += 1 }
        }
        controller.loadUserSelected(lastSubtitle, for: media) {}
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(work.calls, ["parse:first.srt"])

        work.release()
        await waitUntil { controller.track?.url == lastSubtitle }

        XCTAssertEqual(work.calls, ["parse:first.srt", "parse:last.srt"])
        XCTAssertEqual(work.maximumConcurrentCalls, 1)
        XCTAssertEqual(staleActivations, 0)
    }

    func testControllerCanReleaseWhileActualCancelledReadFinishes() async {
        let work = BlockingSubtitleWork()
        defer { work.release() }
        let engine = TestPlaybackEngine()
        var controller: ExternalSubtitleController? = ExternalSubtitleController(
            engine: engine, parser: work
        )
        weak var weakController = controller
        let media = URL(fileURLWithPath: "/tmp/video.mp4")
        controller?.prepare(for: media) {}
        controller?.loadUserSelected(URL(fileURLWithPath: "/tmp/first.srt"), for: media) {}
        await waitUntil { work.calls == ["parse:first.srt"] }

        controller = nil

        XCTAssertNil(weakController)
        work.release()
        await waitUntil { work.completedCalls == 1 }
        XCTAssertEqual(work.maximumConcurrentCalls, 1)
    }

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
        XCTAssertNil(engine.externalSubtitleTimeHandler)
        XCTAssertNotNil(controller.externalSubtitles.track)
        controller.restorePlayerSubtitleSelection()
        XCTAssertNotNil(engine.externalSubtitleTimeHandler)
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
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

/// Ignores cancellation until explicitly released, like synchronous filesystem
/// work that has not yet returned. Discovery and parsing use the same counter.
private final class BlockingSubtitleWork:
    SubtitleFileParsing, ExternalSubtitleDiscovering, @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = true
    private var recordedCalls: [String] = []
    private var activeCalls = 0
    private var peakActiveCalls = 0
    private var finishedCalls = 0

    var calls: [String] { condition.withLock { recordedCalls } }
    var maximumConcurrentCalls: Int { condition.withLock { peakActiveCalls } }
    var completedCalls: Int { condition.withLock { finishedCalls } }

    func parse(_ url: URL) throws -> SubtitleTimeline {
        recordAndWait("parse:" + url.lastPathComponent)
        return SubtitleTimeline(cues: [SubtitleCue(startTime: 1, endTime: 2, text: "Loaded")])
    }

    func discover(for mediaURL: URL, preferredLanguageCodes: [String]) -> URL? {
        recordAndWait("discover:" + mediaURL.lastPathComponent)
        return mediaURL.deletingPathExtension().appendingPathExtension("srt")
    }

    func release() {
        condition.withLock {
            isBlocked = false
            condition.broadcast()
        }
    }

    private func recordAndWait(_ name: String) {
        condition.lock()
        recordedCalls.append(name)
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        while isBlocked { condition.wait() }
        activeCalls -= 1
        finishedCalls += 1
        condition.unlock()
    }
}
