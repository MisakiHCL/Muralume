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

@MainActor
final class ExternalSubtitleAssociationStoreTests: XCTestCase {
    func testLookupCachesRecordsAndCoalescesRecencyWritesOffMainThread() async {
        let probe = SubtitleAssociationProbe()
        let store = makeStore(probe, recencySaveDelay: .milliseconds(100))
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let subtitle = URL(fileURLWithPath: "/tmp/movie.srt")
        await store.save(subtitleURL: subtitle, for: media)
        for _ in 0..<20 {
            let result = await store.subtitleURL(for: media)
            XCTAssertEqual(result, subtitle)
        }
        XCTAssertEqual(probe.readCount, 1)
        XCTAssertEqual(probe.writeCount, 1)
        XCTAssertFalse(probe.didWorkOnMainThread)
        await waitUntil { probe.writeCount == 2 }
        XCTAssertEqual(probe.writeCount, 2)
    }

    func testCacheIsBoundedAndIsolatedBetweenStoreInstances() async throws {
        let firstProbe = SubtitleAssociationProbe()
        let first = makeStore(firstProbe)
        let secondProbe = SubtitleAssociationProbe()
        let second = makeStore(secondProbe)
        for index in 0..<(ExternalSubtitlePolicy.maximumStoredAssociations + 10) {
            await first.save(
                subtitleURL: URL(fileURLWithPath: "/tmp/subtitle-\(index).srt"),
                for: URL(fileURLWithPath: "/tmp/movie-\(index).mp4")
            )
        }
        let encoded = try XCTUnwrap(firstProbe.data)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(records.count, ExternalSubtitlePolicy.maximumStoredAssociations)
        let isolated = await second.subtitleURL(for: URL(fileURLWithPath: "/tmp/movie-73.mp4"))
        XCTAssertNil(isolated)
        XCTAssertEqual(secondProbe.readCount, 1)
        XCTAssertEqual(secondProbe.writeCount, 0)
    }

    func testStaleBookmarkRefreshPersistsAndNextLookupUsesUpdatedRecord() async {
        let probe = SubtitleAssociationProbe()
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let oldSubtitle = URL(fileURLWithPath: "/tmp/old.srt")
        let newSubtitle = URL(fileURLWithPath: "/tmp/new.srt")
        let initial = makeStore(probe)
        await initial.save(subtitleURL: oldSubtitle, for: media)
        let store = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: ExternalSubtitleBookmarkIO(
                resolve: { data in
                    let old = data == Data(oldSubtitle.absoluteString.utf8)
                    return .init(url: newSubtitle, isStale: old)
                },
                create: { Data($0.absoluteString.utf8) }
            ),
            recencySaveDelay: .seconds(60), persistence: probe.persistence
        )
        let first = await store.subtitleURL(for: media)
        XCTAssertEqual(first, newSubtitle)
        XCTAssertEqual(probe.writeCount, 2)
        let second = await store.subtitleURL(for: media)
        XCTAssertEqual(second, newSubtitle)
        XCTAssertEqual(probe.writeCount, 2)
    }

    func testCancelledLookupCannotRestoreAnAssociationRemovedOrReplacedLater() async {
        let probe = SubtitleAssociationProbe()
        let gate = SubtitleBookmarkGate()
        defer { gate.open() }
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let oldSubtitle = URL(fileURLWithPath: "/tmp/old.srt")
        let newSubtitle = URL(fileURLWithPath: "/tmp/new.srt")
        let initial = makeStore(probe)
        await initial.save(subtitleURL: oldSubtitle, for: media)
        let store = makeStore(probe, gate: gate)
        let lookup = Task { await store.subtitleURL(for: media) }
        await waitUntil { gate.isWaiting }
        lookup.cancel()
        let replacement = Task {
            await store.removeSubtitleURL(for: media)
            await store.save(subtitleURL: newSubtitle, for: media)
        }
        gate.open()
        let cancelledResult = await lookup.value
        XCTAssertNil(cancelledResult)
        await replacement.value
        let result = await store.subtitleURL(for: media)
        XCTAssertEqual(result, newSubtitle)
        await store.removeSubtitleURL(for: media)
        let removedResult = await store.subtitleURL(for: media)
        XCTAssertNil(removedResult)
        XCTAssertNil(probe.data)
    }

    private func makeStore(
        _ probe: SubtitleAssociationProbe,
        gate: SubtitleBookmarkGate? = nil,
        recencySaveDelay: Duration = .seconds(60)
    ) -> UserDefaultsExternalSubtitleAssociationStore {
        UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(gate: gate),
            recencySaveDelay: recencySaveDelay, persistence: probe.persistence
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for subtitle association work")
    }
}

extension ExternalSubtitleControllerTests {
    func testClearDuringLookupDoesNotReactivateRemovedAssociationOnImmediatePrepare() async {
        let probe = SubtitleAssociationProbe()
        let gate = SubtitleBookmarkGate()
        defer { gate.open() }
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let remembered = URL(fileURLWithPath: "/tmp/remembered.srt")
        let initial = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(), persistence: probe.persistence
        )
        await initial.save(subtitleURL: remembered, for: media)
        let store = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(gate: gate), persistence: probe.persistence
        )
        let work = BlockingSubtitleWork()
        work.release()
        let controller = ExternalSubtitleController(
            engine: TestPlaybackEngine(), parser: work, associationStore: store
        )
        var activations = 0
        controller.prepare(for: media) { activations += 1 }
        await waitUntil { gate.isWaiting }
        controller.clear(removeRememberedAssociation: true)
        controller.prepare(for: media) { activations += 1 }
        gate.open()
        await waitUntil { probe.data == nil && !controller.isLoading }
        XCTAssertNil(controller.track)
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(work.calls.isEmpty)
    }

    func testRememberedLookupSharesWorkerAndUserSelectionSupersedesLateResult() async {
        let probe = SubtitleAssociationProbe()
        let gate = SubtitleBookmarkGate()
        defer { gate.open() }
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let oldSubtitle = URL(fileURLWithPath: "/tmp/old.srt")
        let newSubtitle = URL(fileURLWithPath: "/tmp/new.srt")
        let initial = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(), persistence: probe.persistence
        )
        await initial.save(subtitleURL: oldSubtitle, for: media)
        let store = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(gate: gate), persistence: probe.persistence
        )
        let work = BlockingSubtitleWork()
        work.release()
        let controller = ExternalSubtitleController(
            engine: TestPlaybackEngine(), parser: work, discovery: work,
            associationStore: store
        )
        var staleActivations = 0
        var selectedActivations = 0
        controller.prepare(for: media) { staleActivations += 1 }
        await waitUntil { gate.isWaiting }
        for index in 0..<100 {
            controller.prepare(for: URL(fileURLWithPath: "/tmp/discarded-\(index).mp4")) {
                staleActivations += 1
            }
        }
        controller.prepare(for: media) { staleActivations += 1 }
        controller.loadUserSelected(newSubtitle, for: media) { selectedActivations += 1 }
        XCTAssertTrue(controller.isLoading)
        XCTAssertTrue(work.calls.isEmpty)
        gate.open()
        await waitUntil { selectedActivations == 1 }
        XCTAssertEqual(controller.track?.url, newSubtitle)
        XCTAssertEqual(controller.track?.origin, .userSelected)
        XCTAssertEqual(work.calls, ["parse:new.srt"])
        XCTAssertEqual(staleActivations, 0)
        let remembered = await store.subtitleURL(for: media)
        XCTAssertEqual(remembered, newSubtitle)
        controller.clear(removeRememberedAssociation: true)
        await waitUntil { probe.data == nil }
        let removed = await store.subtitleURL(for: media)
        XCTAssertNil(removed)
    }

    func testInvalidRememberedSubtitleIsRemovedBeforeDiscoveryFallback() async {
        let probe = SubtitleAssociationProbe()
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let remembered = URL(fileURLWithPath: "/tmp/invalid.srt")
        let fallback = URL(fileURLWithPath: "/tmp/movie.srt")
        let store = UserDefaultsExternalSubtitleAssociationStore(
            bookmarkIO: probe.bookmarkIO(), persistence: probe.persistence
        )
        await store.save(subtitleURL: remembered, for: media)
        let work = FallbackSubtitleWork(invalidURL: remembered, fallbackURL: fallback)
        let controller = ExternalSubtitleController(
            engine: TestPlaybackEngine(), parser: work, discovery: work,
            associationStore: store
        )
        var activations = 0
        controller.prepare(for: media) { activations += 1 }
        await waitUntil { controller.track != nil }
        XCTAssertEqual(controller.track?.url, fallback)
        XCTAssertEqual(controller.track?.origin, .discovered)
        XCTAssertEqual(activations, 1)
        let association = await store.subtitleURL(for: media)
        XCTAssertNil(association)
        XCTAssertNil(probe.data)
    }
}

private final class SubtitleAssociationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var reads = 0
    private var writes = 0
    private var workedOnMainThread = false

    var data: Data? { lock.withLock { storedData } }
    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    var didWorkOnMainThread: Bool { lock.withLock { workedOnMainThread } }

    var persistence: ExternalSubtitleAssociationPersistence {
        ExternalSubtitleAssociationPersistence(
            read: { [self] in
                lock.withLock {
                    reads += 1
                    workedOnMainThread = workedOnMainThread || Thread.isMainThread
                    return storedData
                }
            },
            write: { [self] data in
                lock.withLock {
                    writes += 1
                    workedOnMainThread = workedOnMainThread || Thread.isMainThread
                    storedData = data
                }
            }
        )
    }

    func bookmarkIO(gate: SubtitleBookmarkGate? = nil) -> ExternalSubtitleBookmarkIO {
        ExternalSubtitleBookmarkIO(
            resolve: { [self] data in
                recordThread()
                gate?.wait()
                guard let raw = String(data: data, encoding: .utf8),
                      let url = URL(string: raw) else { return nil }
                return .init(url: url, isStale: false)
            },
            create: { [self] url in
                recordThread()
                return Data(url.absoluteString.utf8)
            }
        )
    }

    private func recordThread() {
        lock.withLock { workedOnMainThread = workedOnMainThread || Thread.isMainThread }
    }
}

private final class SubtitleBookmarkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private var waiting = false
    var isWaiting: Bool { condition.withLock { waiting } }

    func wait() {
        condition.lock()
        waiting = true
        while blocked { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.withLock {
            blocked = false
            condition.broadcast()
        }
    }
}

private struct FallbackSubtitleWork: SubtitleFileParsing, ExternalSubtitleDiscovering {
    let invalidURL: URL
    let fallbackURL: URL
    func parse(_ url: URL) throws -> SubtitleTimeline {
        if url == invalidURL { throw ExternalSubtitleLoadFailure.invalidFormat }
        return SubtitleTimeline(cues: [.init(startTime: 1, endTime: 2, text: "Fallback")])
    }
    func discover(for mediaURL: URL, preferredLanguageCodes: [String]) -> URL? { fallbackURL }
}

extension ExternalSubtitleControllerTests {
    func testParsedSubtitleActivatesBeforeBlockedSaveAndClearDrainsBeforeLaterSave() async {
        let saveGate = SubtitleBookmarkGate()
        let removeGate = SubtitleBookmarkGate()
        defer { saveGate.open(); removeGate.open() }
        let probe = SubtitleAssociationMutationProbe()
        let store = BlockingSubtitleAssociationStore(
            probe: probe, saveGate: saveGate, removeGate: removeGate
        )
        let work = BlockingSubtitleWork()
        work.release()
        let engine = TestPlaybackEngine()
        let controller = ExternalSubtitleController(
            engine: engine, parser: work, associationStore: store
        )
        let media = URL(fileURLWithPath: "/tmp/movie.mp4")
        let first = URL(fileURLWithPath: "/tmp/first.srt")
        let latest = URL(fileURLWithPath: "/tmp/latest.srt")
        var firstActivations = 0
        var latestActivations = 0
        controller.prepare(for: media) {}
        controller.loadUserSelected(first, for: media) { firstActivations += 1 }
        await waitUntil { saveGate.isWaiting }
        XCTAssertEqual(firstActivations, 1)
        XCTAssertEqual(controller.track?.url, first)
        XCTAssertNotNil(engine.externalSubtitleTimeHandler)
        for _ in 0..<1_000 { controller.clear(removeRememberedAssociation: true) }
        controller.loadUserSelected(latest, for: media) { latestActivations += 1 }
        saveGate.open()
        await waitUntil { removeGate.isWaiting }
        XCTAssertEqual(probe.calls, ["save:first.srt", "remove:movie.mp4"])
        for _ in 0..<1_000 { controller.clear(removeRememberedAssociation: true) }
        controller.loadUserSelected(latest, for: media) { latestActivations += 1 }
        removeGate.open()
        await waitUntil { probe.subtitle(for: media) == latest }
        XCTAssertEqual(latestActivations, 1)
        XCTAssertEqual(controller.track?.url, latest)
        XCTAssertEqual(probe.calls, ["save:first.srt", "remove:movie.mp4", "save:latest.srt"])
    }

    func testBlockedAssociationRemovalQueueIsBoundedAndReportsOverflow() async {
        let gate = SubtitleBookmarkGate()
        defer { gate.open() }
        let probe = SubtitleAssociationMutationProbe()
        let store = BlockingSubtitleAssociationStore(probe: probe, removeGate: gate)
        let work = BlockingSubtitleWork()
        work.release()
        let controller = ExternalSubtitleController(
            engine: TestPlaybackEngine(), parser: work, associationStore: store
        )
        controller.prepare(for: URL(fileURLWithPath: "/tmp/first.mp4")) {}
        controller.clear(removeRememberedAssociation: true)
        await waitUntil { gate.isWaiting }
        for index in 0..<(ExternalSubtitlePolicy.maximumPendingAssociationRemovals + 20) {
            controller.prepare(for: URL(fileURLWithPath: "/tmp/movie-\(index).mp4")) {}
            controller.clear(removeRememberedAssociation: true)
        }
        XCTAssertEqual(controller.failure, .cannotRead)
        XCTAssertEqual(probe.calls.count, 1)
        gate.open()
        await waitUntil {
            probe.calls.count == ExternalSubtitlePolicy.maximumPendingAssociationRemovals + 1
        }
        XCTAssertTrue(probe.calls.allSatisfy { $0.hasPrefix("remove:") })
    }
}

private actor BlockingSubtitleAssociationStore: ExternalSubtitleAssociationStoring {
    let probe: SubtitleAssociationMutationProbe
    let saveGate: SubtitleBookmarkGate?
    let removeGate: SubtitleBookmarkGate?

    init(
        probe: SubtitleAssociationMutationProbe,
        saveGate: SubtitleBookmarkGate? = nil,
        removeGate: SubtitleBookmarkGate? = nil
    ) {
        self.probe = probe
        self.saveGate = saveGate
        self.removeGate = removeGate
    }

    func subtitleURL(for mediaURL: URL) -> URL? { probe.subtitle(for: mediaURL) }
    func save(subtitleURL: URL, for mediaURL: URL) {
        probe.record("save:" + subtitleURL.lastPathComponent)
        saveGate?.wait()
        probe.save(subtitleURL, for: mediaURL)
    }
    func removeSubtitleURL(for mediaURL: URL) {
        probe.record("remove:" + mediaURL.lastPathComponent)
        removeGate?.wait()
        probe.save(nil, for: mediaURL)
    }
}

private final class SubtitleAssociationMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var subtitles: [URL: URL] = [:]
    var calls: [String] { lock.withLock { recordedCalls } }
    func record(_ call: String) { lock.withLock { recordedCalls.append(call) } }
    func subtitle(for media: URL) -> URL? { lock.withLock { subtitles[media] } }
    func save(_ subtitle: URL?, for media: URL) {
        lock.withLock { subtitles[media] = subtitle }
    }
}
