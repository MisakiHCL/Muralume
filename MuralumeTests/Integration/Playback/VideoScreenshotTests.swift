import AppKit
import ImageIO
import XCTest
@testable import Muralume

final class VideoScreenshotTests: XCTestCase {
    func testGeneratedJPEGUsesEachVideosNativeAspectAndDimensions()
        async throws
    {
        let generator = AVAssetVideoScreenshotGenerator()
        let fixtures: [(name: String, size: CGSize)] = [
            ("landscape-20s-h264", CGSize(width: 320, height: 180)),
            ("portrait-20s-h264", CGSize(width: 180, height: 320))
        ]

        for fixture in fixtures {
            let url = try XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: fixture.name,
                    withExtension: "mp4"
                )
            )
            let data = try await generator.jpegData(
                for: VideoScreenshotRequest(
                    source: ResolvedMediaSource(
                        url: url,
                        displayName: fixture.name
                    ),
                    time: 1
                )
            )
            let image = try XCTUnwrap(NSBitmapImageRep(data: data))
            let imageSource = try XCTUnwrap(
                CGImageSourceCreateWithData(data as CFData, nil)
            )

            XCTAssertEqual(
                CGImageSourceGetType(imageSource) as String?,
                "public.jpeg"
            )
            XCTAssertEqual(image.pixelsWide, Int(fixture.size.width))
            XCTAssertEqual(image.pixelsHigh, Int(fixture.size.height))
        }
    }

    func testGeneratesJPEGThroughF4VCompatibilityAlias() async throws {
        let fixture = try TestMediaFixture.temporaryCopy(
            for: Self.self,
            fileExtension: "f4v"
        )
        defer { fixture.remove() }

        let data = try await AVAssetVideoScreenshotGenerator().jpegData(
            for: VideoScreenshotRequest(
                source: ResolvedMediaSource(
                    url: fixture.url,
                    displayName: fixture.url.lastPathComponent
                ),
                time: 1
            )
        )
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(image.pixelsWide, 320)
        XCTAssertEqual(image.pixelsHigh, 180)
    }

    func testScreenshotWriterSavesAtomicallyAndHonorsQueuedCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.jpg")
        let writer = FileVideoScreenshotWriter()
        let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let saved = try await writer.write(data, to: destination)
        XCTAssertEqual(saved.url, destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let cancelledDestination = directory.appendingPathComponent("cancelled.jpg")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await writer.write(data, to: cancelledDestination)
        }
        do {
            try await cancelled.value
            XCTFail("Cancelled screenshot write succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDestination.path))
    }

    func testSuggestedFilenameSanitizesSourceNameAndIncludesVideoTime() {
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/ignored.mp4"),
            displayName: "Travel/Day:One.mp4"
        )

        XCTAssertEqual(
            VideoScreenshotFilenameBuilder.filename(
                source: source,
                time: 3_661.9
            ),
            "Travel-Day-One-01-01-01.jpg"
        )
    }

    func testAutomaticScreenshotWritesReserveUniqueNamesAcrossWriters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("frame.jpg")
        let original = Data([1])
        let first = Data([2])
        let second = Data([3])
        try original.write(to: existing)

        let firstWriter = FileVideoScreenshotWriter()
        let secondWriter = FileVideoScreenshotWriter()
        async let firstResult = firstWriter.write(first, named: "frame.jpg", in: directory, customFolder: nil)
        async let secondResult = secondWriter.write(second, named: "frame.jpg", in: directory, customFolder: nil)
        let (firstWrite, secondWrite) = try await (firstResult, secondResult)
        XCTAssertEqual(Set([firstWrite.record.url.lastPathComponent, secondWrite.record.url.lastPathComponent]),
                       Set(["frame-2.jpg", "frame-3.jpg"]))

        XCTAssertEqual(try Data(contentsOf: existing), original)
        let added = try ["frame-2.jpg", "frame-3.jpg"].map {
            try Data(contentsOf: directory.appendingPathComponent($0))
        }
        XCTAssertEqual(Set(added), Set([first, second]))
    }

    @MainActor
    func testScreenshotFolderPersistsAndUsesTheDownloadsLabelForThatDirectory() async throws {
        let suiteName = "muralume.screenshot-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = VideoScreenshotFolder(path: "/chosen", bookmark: Data([1]))
        let selector = ScreenshotFolderSelectorStub(selection: folder)
        let settings = VideoScreenshotFolderController(selector: selector, defaults: defaults)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        XCTAssertEqual(settings.directoryURL, downloads)
        XCTAssertTrue(settings.usesDownloadsName)
        await settings.chooseFolder()
        let restored = VideoScreenshotFolderController(selector: selector, defaults: defaults)
        XCTAssertEqual(restored.customFolder, folder)
        XCTAssertEqual(restored.directoryURL, folder.url)
        XCTAssertFalse(restored.usesDownloadsName)

        selector.selection = nil
        await restored.chooseFolder()
        XCTAssertEqual(restored.customFolder, folder)

        let selectedDownloads = VideoScreenshotFolder(path: try XCTUnwrap(downloads).path, bookmark: Data([2]))
        selector.selection = selectedDownloads
        await restored.chooseFolder()
        XCTAssertEqual(restored.customFolder, selectedDownloads)
        XCTAssertEqual(restored.directoryURL, downloads)
        XCTAssertTrue(restored.usesDownloadsName)
    }

    @MainActor
    func testScreenshotHistoryKeepsRecentUniqueFilesAndInvalidatesClearedActions() {
        var opened: [VideoScreenshotRecord] = []
        let history = VideoScreenshotHistory { record, _ in opened.append(record) }
        for index in 0..<25 {
            history.record(VideoScreenshotRecord(url: URL(fileURLWithPath: "/tmp/frame-\(index).jpg")))
        }
        XCTAssertEqual(history.records.count, 20)
        XCTAssertEqual(history.records.last?.url.lastPathComponent, "frame-5.jpg")

        let file = URL(fileURLWithPath: "/tmp/frame-12.jpg")
        let overwritten = VideoScreenshotRecord(url: file)
        history.record(overwritten)
        XCTAssertEqual(history.records.first, overwritten)
        XCTAssertEqual(history.records.filter { $0.url == file }.count, 1)

        history.perform(.open, on: overwritten)
        history.clear()
        history.perform(.open, on: overwritten)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(opened, [overwritten])
    }
}

@MainActor
private final class ScreenshotFolderSelectorStub: VideoScreenshotFolderSelecting {
    var selection: VideoScreenshotFolder?

    init(selection: VideoScreenshotFolder?) {
        self.selection = selection
    }

    func chooseFolder(startingAt directory: URL?) async throws -> VideoScreenshotFolder? {
        selection
    }
}
