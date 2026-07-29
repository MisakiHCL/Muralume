import AppKit
import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class AVFoundationPlaybackEngineTests: XCTestCase {
    private enum ThumbnailExpectation {
        static let pointSize = CGSize(width: 84, height: 48)
        static let scale: CGFloat = 2
    }

    func testLoadsBundledH264Sample() async throws {
        let engine = AVFoundationPlaybackEngine()

        let duration = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )

        XCTAssertEqual(duration, TestMediaFixture.duration, accuracy: 0.1)
        engine.stop()
    }

    func testBundledH264SampleContainsVisibleColor() async throws {
        let asset = AVURLAsset(
            url: try TestMediaFixture.h264URL(for: Self.self)
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let result = try await generator.image(
            at: CMTime(
                seconds: TestMediaFixture.frameProbeTime,
                preferredTimescale: TestMediaFixture.timeScale
            )
        )
        let bitmap = NSBitmapImageRep(cgImage: result.image)
        let sampleColors = TestMediaFixture.samplePoints.compactMap { point in
            bitmap.colorAt(x: point.x, y: point.y)
        }

        XCTAssertEqual(
            sampleColors.count,
            TestMediaFixture.samplePoints.count
        )
        XCTAssertTrue(
            sampleColors.contains { color in
                color.brightnessComponent > TestMediaFixture.minimumVisibleBrightness
                    && color.saturationComponent > TestMediaFixture.minimumVisibleSaturation
            }
        )
    }

    func testQuickLookProviderGeneratesAndCachesVisibleThumbnail() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let provider = QuickLookMediaThumbnailProvider()

        let generatedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        let image = try XCTUnwrap(generatedImage)

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let bitmap = NSBitmapImageRep(cgImage: image)
        let samplePoints = [
            (x: image.width / 8, y: image.height / 4),
            (x: image.width / 2, y: image.height / 2),
            (x: image.width * 7 / 8, y: image.height * 3 / 4)
        ]
        let sampleColors = samplePoints.compactMap { point in
            bitmap.colorAt(x: point.x, y: point.y)
        }
        XCTAssertEqual(sampleColors.count, samplePoints.count)
        XCTAssertTrue(
            sampleColors.contains { color in
                color.brightnessComponent
                    > TestMediaFixture.minimumVisibleBrightness
                    && color.saturationComponent
                    > TestMediaFixture.minimumVisibleSaturation
            }
        )

        let cachedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        XCTAssertTrue(image === cachedImage)
    }

    func testQuickLookProviderReturnsNilForMissingMedia() async {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let missingURL = rootURL.appendingPathComponent(
            "muralume-missing-thumbnail.mp4"
        )
        let item = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Missing",
            url: missingURL,
            displayName: "Missing",
            relativePath: missingURL.lastPathComponent,
            relativeDirectory: "",
            creationDate: nil,
            modificationDate: nil,
            fileSize: 0
        )

        let image = await QuickLookMediaThumbnailProvider().thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertNil(image)
    }

    func testQuickLookProviderRejectsRequestsAfterShutdown() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let provider = QuickLookMediaThumbnailProvider()

        await provider.shutdown()
        let image = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertNil(image)
    }

    func testReattachingTheSameSurfaceWaitsForItToBecomeReady() async throws {
        let engine = AVFoundationPlaybackEngine()
        let surface = TestAVPlayerSurface(id: .player)

        try await engine.attach(to: surface)
        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        surface.isReadyForDisplay = false

        var didFinishAttachment = false
        let attachmentTask = Task {
            try await engine.attach(to: surface)
            didFinishAttachment = true
        }
        try await Task.sleep(nanoseconds: TestMediaFixture.readinessProbeNanoseconds)
        XCTAssertFalse(didFinishAttachment)

        surface.isReadyForDisplay = true
        try await attachmentTask.value
        XCTAssertTrue(didFinishAttachment)
        engine.stop()
    }

    func testReplacingASurfaceWithTheSameIDDisconnectsTheOldInstance() async throws {
        let engine = AVFoundationPlaybackEngine()
        let firstSurface = TestAVPlayerSurface(id: .player)
        let replacementSurface = TestAVPlayerSurface(id: .player)

        try await engine.attach(to: firstSurface)
        XCTAssertTrue(firstSurface.isConnected)

        try await engine.attach(to: replacementSurface)

        XCTAssertFalse(firstSurface.isConnected)
        XCTAssertTrue(replacementSurface.isConnected)
        engine.stop()
    }

    func testRejectsASurfaceFromAnotherPlaybackAdapter() async {
        let engine = AVFoundationPlaybackEngine()
        let incompatibleSurface = TestPlaybackSurface(id: .player)

        do {
            try await engine.attach(to: incompatibleSurface)
            XCTFail("Expected the AVFoundation adapter to reject an incompatible surface")
        } catch let error as PlaybackEngineError {
            XCTAssertEqual(error, .incompatibleSurface)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeLibraryItem(
        for url: URL
    ) throws -> LibraryMediaItem {
        let values = try url.resourceValues(
            forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey
            ]
        )
        let rootURL = url.deletingLastPathComponent()

        return LibraryMediaItem(
            rootURL: rootURL,
            rootName: rootURL.lastPathComponent,
            url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            relativePath: url.lastPathComponent,
            relativeDirectory: "",
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }
}
