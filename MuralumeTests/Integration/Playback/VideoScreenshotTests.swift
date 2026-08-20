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
