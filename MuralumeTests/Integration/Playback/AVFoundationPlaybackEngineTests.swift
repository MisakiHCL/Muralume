import AppKit
import AVFoundation
import QuickLookThumbnailing
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

    func testQuickLookProviderPurgesMemoryCacheAndRemainsUsable() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = CountingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator
        )

        let firstImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        let cachedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertTrue(firstImage === thumbnail)
        XCTAssertTrue(cachedImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 1)

        provider.purgeMemoryCache()

        let regeneratedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertTrue(regeneratedImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 2)
        await provider.shutdown()
    }

    func testQuickLookProviderDoesNotCacheWithoutModificationDate()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let item = LibraryMediaItem(
            rootURL: scannedItem.rootURL,
            rootName: scannedItem.rootName,
            url: scannedItem.url,
            displayName: scannedItem.displayName,
            relativePath: scannedItem.relativePath,
            relativeDirectory: scannedItem.relativeDirectory,
            creationDate: scannedItem.creationDate,
            modificationDate: nil,
            fileSize: scannedItem.fileSize
        )
        let thumbnail = try makeTestThumbnail()
        let generator = CountingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator
        )

        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertEqual(generator.generationCount, 2)
        await provider.shutdown()
    }

    func testQuickLookProviderInvalidatesCacheForMetadataAndPixelChanges()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let modificationDate = try XCTUnwrap(item.modificationDate)
        let changedDateItem = replacingMetadata(
            in: item,
            fileSize: item.fileSize,
            modificationDate: modificationDate.addingTimeInterval(1)
        )
        let changedSizeItem = replacingMetadata(
            in: item,
            fileSize: item.fileSize + 1,
            modificationDate: modificationDate
        )
        let generator = CountingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let provider = QuickLookMediaThumbnailProvider(generator: generator)

        for _ in 0..<2 {
            _ = await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        _ = await provider.thumbnail(
            for: changedDateItem,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        _ = await provider.thumbnail(
            for: changedSizeItem,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale + 1
        )

        XCTAssertEqual(generator.generationCount, 4)
        await provider.shutdown()
    }

    func testConcurrentRequestsForSameThumbnailShareGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(generator: generator)

        let firstRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            firstRequest.cancel()
            return
        }

        let secondRequestDidStart = TestFlag()
        let secondRequest = Task {
            secondRequestDidStart.value = true
            return await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await waitForFlag(secondRequestDidStart)

        XCTAssertEqual(generator.generationCount, 1)
        generator.finishNextRequest()
        let firstImage = await firstRequest.value
        let secondImage = await secondRequest.value

        XCTAssertTrue(firstImage === thumbnail)
        XCTAssertTrue(secondImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 1)
        await provider.shutdown()
    }

    func testCancellingOneSharedWaiterKeepsGenerationAlive() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(generator: generator)

        let cancelledRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            cancelledRequest.cancel()
            return
        }

        let survivingRequestDidStart = TestFlag()
        let survivingRequest = Task {
            survivingRequestDidStart.value = true
            return await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await waitForFlag(survivingRequestDidStart)

        cancelledRequest.cancel()
        let cancelledImage = await cancelledRequest.value
        XCTAssertNil(cancelledImage)
        XCTAssertEqual(generator.cancellationCount, 0)

        generator.finishNextRequest()
        let survivingImage = await survivingRequest.value
        XCTAssertTrue(survivingImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 1)
        await provider.shutdown()
    }

    func testCancellingLastWaiterCancelsGenerationAndShutdownDrainsIt()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(generator: generator)

        let request = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            request.cancel()
            return
        }

        request.cancel()
        let image = await request.value

        XCTAssertNil(image)
        XCTAssertEqual(generator.cancellationCount, 1)

        let shutdownStarted = TestFlag()
        let shutdownFinished = TestFlag()
        let shutdown = Task {
            shutdownStarted.value = true
            await provider.shutdown()
            shutdownFinished.value = true
        }
        await waitForFlag(shutdownStarted)
        XCTAssertFalse(shutdownFinished.value)

        generator.finishNextRequest()
        await shutdown.value
        XCTAssertTrue(shutdownFinished.value)
    }

    func testConcurrentShutdownCallsWaitForActiveGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(generator: generator)

        let request = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            request.cancel()
            return
        }

        let firstShutdownFinished = TestFlag()
        let secondShutdownFinished = TestFlag()
        let firstShutdown = Task {
            await provider.shutdown()
            firstShutdownFinished.value = true
        }
        let secondShutdown = Task {
            await provider.shutdown()
            secondShutdownFinished.value = true
        }
        await waitForCancellationCount(1, generator: generator)

        XCTAssertFalse(firstShutdownFinished.value)
        XCTAssertFalse(secondShutdownFinished.value)
        generator.finishNextRequest()

        await firstShutdown.value
        await secondShutdown.value
        let requestImage = await request.value
        XCTAssertNil(requestImage)
        XCTAssertTrue(firstShutdownFinished.value)
        XCTAssertTrue(secondShutdownFinished.value)
        XCTAssertEqual(generator.cancellationCount, 1)
    }

    func testRequestStartedBeforePurgeDoesNotRepopulateMemoryCache() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator
        )

        let staleRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            staleRequest.cancel()
            return
        }

        provider.purgeMemoryCache()
        XCTAssertEqual(generator.cancellationCount, 0)
        generator.finishNextRequest()
        let staleImage = await staleRequest.value
        XCTAssertTrue(staleImage === thumbnail)

        let freshRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(2, generator: generator) else {
            freshRequest.cancel()
            return
        }
        XCTAssertEqual(generator.generationCount, 2)
        generator.finishNextRequest()
        let freshImage = await freshRequest.value
        XCTAssertTrue(freshImage === thumbnail)

        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        XCTAssertEqual(generator.generationCount, 2)
        await provider.shutdown()
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

    private func replacingMetadata(
        in item: LibraryMediaItem,
        fileSize: Int64,
        modificationDate: Date?
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: item.rootURL,
            rootName: item.rootName,
            url: item.url,
            displayName: item.displayName,
            relativePath: item.relativePath,
            relativeDirectory: item.relativeDirectory,
            creationDate: item.creationDate,
            modificationDate: modificationDate,
            fileSize: fileSize
        )
    }

    private func makeTestThumbnail() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        )
        context.setFillColor(
            NSColor.systemPurple.cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func waitForGenerationCount(
        _ expectedCount: Int,
        generator: BlockingQuickLookThumbnailGenerator
    ) async -> Bool {
        for _ in 0..<100 where generator.generationCount < expectedCount {
            await Task.yield()
        }
        XCTAssertEqual(generator.generationCount, expectedCount)
        return generator.generationCount == expectedCount
    }

    private func waitForFlag(_ flag: TestFlag) async {
        for _ in 0..<100 where !flag.value {
            await Task.yield()
        }
        XCTAssertTrue(flag.value)
    }

    private func waitForCancellationCount(
        _ expectedCount: Int,
        generator: BlockingQuickLookThumbnailGenerator
    ) async {
        for _ in 0..<100 where generator.cancellationCount < expectedCount {
            await Task.yield()
        }
        XCTAssertEqual(generator.cancellationCount, expectedCount)
    }
}

@MainActor
private final class TestFlag {
    var value = false
}

@MainActor
private final class CountingQuickLookThumbnailGenerator:
    QuickLookThumbnailGenerating {
    private let image: CGImage
    private(set) var generationCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func generateImage(
        for request: QLThumbnailGenerator.Request
    ) async throws -> CGImage {
        generationCount += 1
        return image
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {}
}

@MainActor
private final class BlockingQuickLookThumbnailGenerator:
    QuickLookThumbnailGenerating {
    private let image: CGImage
    private var continuations: [CheckedContinuation<CGImage, Error>] = []
    private(set) var generationCount = 0
    private(set) var cancellationCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func generateImage(
        for request: QLThumbnailGenerator.Request
    ) async throws -> CGImage {
        generationCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {
        cancellationCount += 1
    }

    func finishNextRequest() {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: image)
    }
}
