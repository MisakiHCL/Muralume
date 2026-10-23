import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class EmbeddedSubtitlePlaybackTests: XCTestCase {
    func testLoadAndSelectionDoNotWaitForParsingAndKeepNativeFallback() async throws {
        let parser = GatedEmbeddedSubtitleParser()
        let player = AVPlayer()
        let engine = AVFoundationPlaybackEngine(player: player, embeddedSubtitleParser: parser)
        defer { engine.stop() }
        let playerSurface = SubtitleTestSurface(id: .player)
        let desktopSurface = SubtitleTestSurface(id: .desktop)
        try await engine.attach(to: playerSurface)
        var cue: String?
        engine.setEmbeddedSubtitleCueHandler { cue = $0 }
        _ = try await engine.load(try source())
        _ = engine.selectSubtitles(.off)
        let chineseID = try XCTUnwrap(engine.currentMediaSelectionState().subtitleOptions.first {
            $0.languageIdentifier == "zh"
        }?.id)
        _ = engine.selectSubtitles(.option(chineseID))
        try await waitUntil { await parser.languages == ["zh"] }
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
        XCTAssertEqual(engine.currentMediaSelectionState().effectiveSubtitleOptionID, chineseID)
        try await engine.attach(to: desktopSurface)
        XCTAssertTrue((player.currentItem?.outputs.first as? AVPlayerItemLegibleOutput)?
            .suppressesPlayerRendering == true)
        try await engine.attach(to: playerSurface)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
        await engine.seekBeforePlayback(to: 0.75)
        await parser.releaseFirst(text: "第一条字幕")
        try await waitUntil { cue == "第一条字幕" }
        XCTAssertEqual(player.currentItem?.outputs.count, 1)
        XCTAssertEqual(engine.currentMediaSelectionState().effectiveSubtitleOptionID, chineseID)
        _ = engine.selectSubtitles(.off)
        XCTAssertNil(cue)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
        await engine.drainPendingWork()
    }

    func testLoopingDesktopDoesNotStartSubtitleParsing() async throws {
        let parser = GatedEmbeddedSubtitleParser()
        let engine = AVFoundationPlaybackEngine(embeddedSubtitleParser: parser)
        engine.setEmbeddedSubtitleCueHandler { _ in }
        engine.setLooping(true)
        _ = try await engine.load(try source())
        for _ in 0..<20 { await Task.yield() }
        let requests = await parser.languages
        XCTAssertTrue(requests.isEmpty)
        engine.stop()
        await engine.drainPendingWork()
    }

    func testOnlyLatestSelectionRunsAfterCancelledParserDrains() async throws {
        let parser = GatedEmbeddedSubtitleParser()
        var published: String?
        let controller = EmbeddedSubtitlePlaybackController(parser: parser) {
            published = $0?.text(at: 0.75)
        }
        let url = try source().url
        controller.request(id: .init(rawValue: "one"), sourceURL: url,
                           language: "en", selectableLanguages: ["en", "zh"])
        try await waitUntil { await parser.languages.count == 1 }
        controller.request(id: .init(rawValue: "two"), sourceURL: url,
                           language: "en", selectableLanguages: ["en", "zh"])
        controller.request(id: .init(rawValue: "three"), sourceURL: url,
                           language: "zh", selectableLanguages: ["en", "zh"])
        for _ in 0..<20 { await Task.yield() }
        let initialRequests = await parser.languages
        XCTAssertEqual(initialRequests, ["en"])
        await parser.releaseFirst(text: "stale")
        try await waitUntil { await parser.languages == ["en", "zh"] }
        XCTAssertNil(published)
        controller.cancel()
        await controller.drain(timeout: .milliseconds(10))
        XCTAssertNil(published)
        await parser.releaseFirst(text: "also stale")
        await controller.drain()
        XCTAssertNil(published)
    }

    func testInvalidUnselectedTrackKeepsNativeRenderingAndCachesFailure() async throws {
        let parser = GatedEmbeddedSubtitleParser(isEligible: false)
        let player = AVPlayer()
        let engine = AVFoundationPlaybackEngine(player: player, embeddedSubtitleParser: parser)
        engine.setEmbeddedSubtitleCueHandler { _ in }
        defer { engine.stop() }
        _ = try await engine.load(try source())
        let options = engine.currentMediaSelectionState().subtitleOptions
        _ = engine.selectSubtitles(.option(try XCTUnwrap(options.first?.id)))
        await engine.drainPendingWork()
        let firstValidationCount = await parser.validationCount
        XCTAssertEqual(firstValidationCount, 1)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
        _ = engine.selectSubtitles(.option(try XCTUnwrap(options.last?.id)))
        await engine.drainPendingWork()
        let secondValidationCount = await parser.validationCount
        let parsedLanguages = await parser.languages
        XCTAssertEqual(secondValidationCount, 1)
        XCTAssertTrue(parsedLanguages.isEmpty)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true)
    }

    func testParserPreservesEligibilityAndEnforcesTotalTextBudget() async throws {
        let url = try source().url
        let parser = EmbeddedSubtitleParser()
        let preparation = try await parser.prepare(
            url, languageIdentifier: "zh", selectableLanguages: ["en", "zh"]
        )
        XCTAssertTrue(preparation.isEligible)
        XCTAssertEqual(preparation.timeline?.text(at: 0.75), "第一条字幕")
        let eligibility = try await parser.validate(url, selectableLanguages: ["en", "zh"])
        XCTAssertTrue(eligibility)
        let english = try await parser.parse(url, languageIdentifier: "en",
                                              selectableLanguages: ["en", "zh"])
        XCTAssertEqual(english?.text(at: 0.75), "First caption")
        let incompleteMapping = try await parser.parse(url, languageIdentifier: "en",
                                                       selectableLanguages: ["en"])
        XCTAssertNil(incompleteMapping)
        let ambiguousMapping = try await parser.parse(url, languageIdentifier: "en",
                                                      selectableLanguages: ["en", "en"])
        XCTAssertNil(ambiguousMapping)
        let overBudget = try await EmbeddedSubtitleParser(maximumTimelineUTF8Bytes: 1)
            .parse(url, languageIdentifier: "en", selectableLanguages: ["en", "zh"])
        XCTAssertNil(overBudget)
        let cancelled = Task {
            try await parser.parse(url, languageIdentifier: "en",
                                   selectableLanguages: ["en", "zh"])
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled parser returned a timeline")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExternalSubtitleClockResumesImmediatelyAtCurrentTime() async throws {
        let engine = AVFoundationPlaybackEngine()
        defer { engine.stop() }
        _ = try await engine.load(try source())
        await engine.seekBeforePlayback(to: 0.75)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("srt")
        try Data("1\n00:00:00,500 --> 00:00:01,000\nExternal".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = PlaybackMediaSelectionController(engine: engine,
                                                           externalSubtitleParser: SubtitleFileParser())
        controller.refresh()
        controller.prepareExternalSubtitles(for: try source().url)
        controller.loadExternalSubtitle(url, for: try source().url)
        try await waitUntil { controller.externalSubtitles.cueText == "External" }
        controller.suppressSubtitlesForDesktop()
        await engine.seekBeforePlayback(to: 2)
        XCTAssertEqual(controller.externalSubtitles.cueText, "External")
        XCTAssertNotNil(controller.externalSubtitles.track)
        controller.restorePlayerSubtitleSelection()
        XCTAssertNil(controller.externalSubtitles.cueText)
        XCTAssertNotNil(controller.externalSubtitles.track)
    }

    private func source() throws -> ResolvedMediaSource {
        ResolvedMediaSource(url: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "alternate-tracks-5s", withExtension: "mp4"
        )), displayName: "Alternate Tracks")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for subtitle work")
        throw SubtitleTestTimeout()
    }
}

private struct SubtitleTestTimeout: Error {}

private actor GatedEmbeddedSubtitleParser: EmbeddedSubtitleParsing {
    private(set) var languages: [String] = []
    private(set) var validationCount = 0
    private let isEligible: Bool

    init(isEligible: Bool = true) { self.isEligible = isEligible }

    func validate(_ url: URL, selectableLanguages: [String]) async throws -> Bool {
        validationCount += 1
        return isEligible
    }
    private var waiters: [CheckedContinuation<SubtitleTimeline?, Never>] = []

    func parse(_ url: URL, languageIdentifier: String, selectableLanguages: [String]) async throws
        -> SubtitleTimeline? {
        languages.append(languageIdentifier)
        // Intentionally ignores cancellation until released to exercise drain
        // bounds and prevent an old response replacing the newest selection.
        return await withCheckedContinuation { waiters.append($0) }
    }

    func releaseFirst(text: String) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: SubtitleTimeline(cues: [
            SubtitleCue(startTime: 0.5, endTime: 1, text: text)
        ]))
    }
}

@MainActor
private final class SubtitleTestSurface: AVPlayerRenderSurface {
    let id: PlaybackSurfaceID
    var isReadyForDisplay: Bool { true }
    init(id: PlaybackSurfaceID) { self.id = id }
    func connect(to player: AVPlayer?) {}
}
