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
        try await writer.write(data, to: destination)
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
}
