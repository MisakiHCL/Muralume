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
        static let drainDeadline: Duration = .milliseconds(20)
    }

    private enum PlaybackExpectation {
        static let seekAccuracy: TimeInterval = 0.25
        static let pollAttempts = 100
        static let pollIntervalNanoseconds: UInt64 = 50_000_000
        static let staleSeekSettleNanoseconds: UInt64 = 300_000_000
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

    func testRapidInteractiveSeekEndsAtExactReleaseTarget() async throws {
        let engine = AVFoundationPlaybackEngine()
        var latestProgress: TimeInterval?
        engine.progressHandler = { latestProgress = $0 }
        engine.setProgressCadence(.visible)
        defer { engine.stop() }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        engine.seek(to: 3, mode: .interactive)
        engine.seek(to: 6, mode: .interactive)
        engine.seek(to: 11, mode: .interactive)
        engine.seek(to: 7, mode: .exact)

        let reachedTarget = await waitForPlaybackProgress(
            7,
            latestProgress: { latestProgress }
        )
        XCTAssertTrue(reachedTarget)
    }

    func testLoadingNewItemCancelsSeeksFromPreviousItem() async throws {
        let engine = AVFoundationPlaybackEngine()
        var latestProgress: TimeInterval?
        engine.progressHandler = { latestProgress = $0 }
        engine.setProgressCadence(.visible)
        defer { engine.stop() }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Landscape"
            )
        )
        engine.seek(to: 18, mode: .interactive)
        engine.seek(to: 19, mode: .interactive)

        let portraitURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "portrait-20s-h264",
                withExtension: "mp4"
            )
        )
        _ = try await engine.load(
            ResolvedMediaSource(
                url: portraitURL,
                displayName: "Portrait"
            )
        )
        engine.seek(to: 4, mode: .exact)

        let reachedTarget = await waitForPlaybackProgress(
            4,
            latestProgress: { latestProgress }
        )
        XCTAssertTrue(reachedTarget)
        try await Task.sleep(
            nanoseconds: PlaybackExpectation.staleSeekSettleNanoseconds
        )
        XCTAssertEqual(
            try XCTUnwrap(latestProgress),
            4,
            accuracy: PlaybackExpectation.seekAccuracy
        )
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
            generator: generator,
            cacheMissDelay: .zero
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
            generator: generator,
            cacheMissDelay: .zero
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
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

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
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

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

    func testConcurrentRequestJoinsGenerationBeforeCacheMissDelay()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let cacheMissGate = FirstCacheMissGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60),
            cacheMissDelayer: cacheMissGate.wait
        )
        let firstRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForCacheMissCount(1, gate: cacheMissGate) else {
            cacheMissGate.open()
            firstRequest.cancel()
            return
        }
        cacheMissGate.open()
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

        XCTAssertEqual(cacheMissGate.waitCount, 1)
        XCTAssertEqual(generator.generationCount, 1)
        generator.finishNextRequest()
        let firstImage = await firstRequest.value
        let secondImage = await secondRequest.value

        XCTAssertTrue(firstImage === thumbnail)
        XCTAssertTrue(secondImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 1)
        await provider.shutdown()
    }

    func testCancellingDuringCacheMissDelaySkipsQuickLookGeneration()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let generator = BlockingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60)
        )
        let requestStarted = TestFlag()
        let request = Task {
            requestStarted.value = true
            return await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await waitForFlag(requestStarted)

        request.cancel()
        let image = await request.value

        XCTAssertNil(image)
        XCTAssertEqual(generator.generationCount, 0)
        XCTAssertEqual(generator.cancellationCount, 0)
        await provider.shutdown()
    }

    func testInvalidatingRootDuringCacheMissDelaySkipsGeneration()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let generator = BlockingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let cacheMissGate = FirstCacheMissGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60),
            cacheMissDelayer: cacheMissGate.wait
        )
        let request = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForCacheMissCount(1, gate: cacheMissGate) else {
            cacheMissGate.open()
            request.cancel()
            return
        }

        await provider.invalidateThumbnails(
            forRootID: MediaLibraryRoot.ID(
                standardizedPath: item.id.rootPath
            )
        )
        cacheMissGate.open()
        let image = await request.value

        XCTAssertNil(image)
        XCTAssertEqual(generator.generationCount, 0)
        XCTAssertEqual(generator.cancellationCount, 0)
        await provider.shutdown()
    }

    func testShutdownDuringCacheMissDelaySkipsGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let generator = BlockingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let cacheMissGate = FirstCacheMissGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60),
            cacheMissDelayer: cacheMissGate.wait
        )
        let request = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForCacheMissCount(1, gate: cacheMissGate) else {
            cacheMissGate.open()
            request.cancel()
            return
        }

        await provider.shutdown()
        cacheMissGate.open()
        let image = await request.value

        XCTAssertNil(image)
        XCTAssertEqual(generator.generationCount, 0)
        XCTAssertEqual(generator.cancellationCount, 0)
    }

    func testCacheFilledDuringDelayAvoidsDuplicateGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = CountingQuickLookThumbnailGenerator(image: thumbnail)
        let cacheMissGate = FirstCacheMissGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60),
            cacheMissDelayer: cacheMissGate.wait
        )
        let delayedRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForCacheMissCount(1, gate: cacheMissGate) else {
            cacheMissGate.open()
            delayedRequest.cancel()
            return
        }

        let generatedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        cacheMissGate.open()
        let delayedImage = await delayedRequest.value

        XCTAssertTrue(generatedImage === thumbnail)
        XCTAssertTrue(delayedImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 1)
        await provider.shutdown()
    }

    func testPurgeDuringCacheMissDelayPreventsStaleCacheRepopulation()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = CountingQuickLookThumbnailGenerator(image: thumbnail)
        let cacheMissGate = FirstCacheMissGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .seconds(60),
            cacheMissDelayer: cacheMissGate.wait
        )
        let staleRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForCacheMissCount(1, gate: cacheMissGate) else {
            cacheMissGate.open()
            staleRequest.cancel()
            return
        }

        provider.purgeMemoryCache()
        cacheMissGate.open()
        let staleImage = await staleRequest.value
        let freshImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        _ = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )

        XCTAssertTrue(staleImage === thumbnail)
        XCTAssertTrue(freshImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 2)
        await provider.shutdown()
    }

    func testCancellingOneSharedWaiterKeepsGenerationAlive() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

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
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

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
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

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

    func testShutdownDeadlineAbandonsNonCooperativeGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let generator = BlockingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let drainDeadlineGate = DrainDeadlineGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            drainDeadline: ThumbnailExpectation.drainDeadline,
            drainDelayer: drainDeadlineGate.wait
        )
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

        let shutdownFinished = TestFlag()
        let shutdown = Task {
            await provider.shutdown()
            shutdownFinished.value = true
        }
        await waitForCancellationCount(1, generator: generator)
        let requestImage = await request.value
        guard await waitForDrainDeadlineCount(
            1,
            gate: drainDeadlineGate
        ) else {
            generator.finishAllRequests()
            await shutdown.value
            return
        }
        XCTAssertFalse(shutdownFinished.value)
        drainDeadlineGate.openNext()
        await waitForFlag(shutdownFinished)
        let finishedBeforeGeneratorReturned = shutdownFinished.value
        if !finishedBeforeGeneratorReturned {
            generator.finishNextRequest()
        }
        await shutdown.value

        XCTAssertNil(requestImage)
        XCTAssertTrue(finishedBeforeGeneratorReturned)
        XCTAssertEqual(generator.activeGenerationCount, 1)
        XCTAssertEqual(
            drainDeadlineGate.requestedDeadlines,
            [ThumbnailExpectation.drainDeadline]
        )

        // A system callback arriving after shutdown must be inert.
        generator.finishAllRequests()
        await allowPendingTasksToRegister()
        let rejectedImage = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        XCTAssertNil(rejectedImage)
        XCTAssertEqual(generator.generationCount, 1)
    }

    func testInvalidatingRootDrainsOnlyItsRequestsAndAllowsReadding()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let firstRootURL = URL(fileURLWithPath: "/tmp/FirstThumbnailRoot")
        let secondRootURL = URL(fileURLWithPath: "/tmp/SecondThumbnailRoot")
        let firstItem = replacingRoot(in: scannedItem, with: firstRootURL)
        let secondItem = replacingRoot(in: scannedItem, with: secondRootURL)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
        )

        let firstRequest = Task {
            await provider.thumbnail(
                for: firstItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            firstRequest.cancel()
            return
        }
        let secondRequest = Task {
            await provider.thumbnail(
                for: secondItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(2, generator: generator) else {
            firstRequest.cancel()
            secondRequest.cancel()
            return
        }

        let invalidationFinished = TestFlag()
        let invalidation = Task {
            await provider.invalidateThumbnails(
                forRootID: MediaLibraryRoot.ID(
                    standardizedPath: firstRootURL.path
                )
            )
            invalidationFinished.value = true
        }
        await waitForCancellationCount(1, generator: generator)

        let firstImage = await firstRequest.value
        XCTAssertNil(firstImage)
        XCTAssertFalse(invalidationFinished.value)
        XCTAssertEqual(generator.cancellationCount, 1)

        generator.finishNextRequest()
        await invalidation.value
        XCTAssertTrue(invalidationFinished.value)
        XCTAssertEqual(generator.cancellationCount, 1)

        generator.finishNextRequest()
        let secondImage = await secondRequest.value
        XCTAssertTrue(secondImage === thumbnail)

        let rejectedImage = await provider.thumbnail(
            for: firstItem,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        XCTAssertNil(rejectedImage)
        XCTAssertEqual(generator.generationCount, 2)

        provider.allowThumbnails(
            forRootIDs: [
                MediaLibraryRoot.ID(
                    standardizedPath: firstRootURL.path
                )
            ]
        )
        let readdedRequest = Task {
            await provider.thumbnail(
                for: firstItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(3, generator: generator) else {
            readdedRequest.cancel()
            return
        }
        generator.finishNextRequest()
        let readdedImage = await readdedRequest.value
        XCTAssertTrue(readdedImage === thumbnail)
        await provider.shutdown()
    }

    func testRootDrainDeadlineIsolatesLateCompletionFromReaddedRoot()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let rootURL = URL(fileURLWithPath: "/tmp/ThumbnailDrainDeadline")
        let item = replacingRoot(in: scannedItem, with: rootURL)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let drainDeadlineGate = DrainDeadlineGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 1,
            drainDeadline: ThumbnailExpectation.drainDeadline,
            drainDelayer: drainDeadlineGate.wait
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

        let invalidationFinished = TestFlag()
        let invalidation = Task {
            await provider.invalidateThumbnails(
                forRootID: MediaLibraryRoot.ID(
                    standardizedPath: rootURL.path
                )
            )
            invalidationFinished.value = true
        }
        await waitForCancellationCount(1, generator: generator)
        let staleImage = await staleRequest.value
        guard await waitForDrainDeadlineCount(
            1,
            gate: drainDeadlineGate
        ) else {
            generator.finishAllRequests()
            await invalidation.value
            return
        }
        XCTAssertFalse(invalidationFinished.value)
        drainDeadlineGate.openNext()
        await waitForFlag(invalidationFinished)
        let finishedBeforeGeneratorReturned = invalidationFinished.value
        if !finishedBeforeGeneratorReturned {
            generator.finishNextRequest()
        }
        await invalidation.value

        XCTAssertNil(staleImage)
        XCTAssertTrue(finishedBeforeGeneratorReturned)
        XCTAssertEqual(generator.activeGenerationCount, 1)
        XCTAssertEqual(
            drainDeadlineGate.requestedDeadlines,
            [ThumbnailExpectation.drainDeadline]
        )

        provider.allowThumbnails(
            forRootIDs: [
                MediaLibraryRoot.ID(standardizedPath: rootURL.path)
            ]
        )
        let freshRequestFinished = TestFlag()
        let freshRequest = Task {
            let image = await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
            freshRequestFinished.value = true
            return image
        }
        guard await waitForGenerationCount(2, generator: generator) else {
            freshRequest.cancel()
            generator.finishAllRequests()
            return
        }

        // The first completion belongs to the timed-out request and must not
        // fulfill or cache on behalf of the new request for the reauthorized root.
        generator.finishNextRequest()
        await allowPendingTasksToRegister()
        XCTAssertFalse(freshRequestFinished.value)

        let joinedRequestFinished = TestFlag()
        let joinedRequest = Task {
            let image = await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
            joinedRequestFinished.value = true
            return image
        }
        await allowPendingTasksToRegister()
        XCTAssertFalse(joinedRequestFinished.value)
        XCTAssertEqual(generator.generationCount, 2)

        generator.finishNextRequest()
        let freshImage = await freshRequest.value
        let joinedImage = await joinedRequest.value
        XCTAssertTrue(freshImage === thumbnail)
        XCTAssertTrue(joinedImage === thumbnail)
        XCTAssertEqual(generator.activeGenerationCount, 0)
        await provider.shutdown()
    }

    func testRepeatedRootDrainDeadlinesRespectActualInFlightBudget()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let rootURL = URL(
            fileURLWithPath: "/tmp/ThumbnailRepeatedDrainDeadline"
        )
        let rootID = MediaLibraryRoot.ID(standardizedPath: rootURL.path)
        let item = replacingRoot(in: scannedItem, with: rootURL)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let drainDeadlineGate = DrainDeadlineGate()
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 1,
            drainDeadline: ThumbnailExpectation.drainDeadline,
            drainDelayer: drainDeadlineGate.wait
        )

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
        let firstInvalidation = Task {
            await provider.invalidateThumbnails(forRootID: rootID)
        }
        await waitForCancellationCount(1, generator: generator)
        let firstImage = await firstRequest.value
        XCTAssertNil(firstImage)
        guard await waitForDrainDeadlineCount(
            1,
            gate: drainDeadlineGate
        ) else {
            generator.finishAllRequests()
            return
        }
        drainDeadlineGate.openNext()
        await firstInvalidation.value

        provider.allowThumbnails(forRootIDs: [rootID])
        let secondRequest = Task {
            await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(2, generator: generator) else {
            secondRequest.cancel()
            generator.finishAllRequests()
            return
        }
        let secondInvalidation = Task {
            await provider.invalidateThumbnails(forRootID: rootID)
        }
        await waitForCancellationCount(2, generator: generator)
        let secondImage = await secondRequest.value
        XCTAssertNil(secondImage)
        guard await waitForDrainDeadlineCount(
            2,
            gate: drainDeadlineGate
        ) else {
            generator.finishAllRequests()
            return
        }
        drainDeadlineGate.openNext()
        await secondInvalidation.value

        XCTAssertEqual(generator.activeGenerationCount, 2)
        XCTAssertEqual(generator.maximumActiveGenerationCount, 2)

        provider.allowThumbnails(forRootIDs: [rootID])
        let thirdRequestFinished = TestFlag()
        let thirdRequest = Task {
            let image = await provider.thumbnail(
                for: item,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
            thirdRequestFinished.value = true
            return image
        }
        await allowPendingTasksToRegister()

        // Both real Quick Look slots are occupied by generations that ignored
        // cancellation, so a third replacement must remain queued.
        XCTAssertEqual(generator.generationCount, 2)
        XCTAssertEqual(generator.activeGenerationCount, 2)
        XCTAssertFalse(thirdRequestFinished.value)

        // A real late callback frees the hard-budget slot. It must only start
        // the queued generation, never publish its own stale result.
        generator.finishNextRequest()
        guard await waitForGenerationCount(3, generator: generator) else {
            thirdRequest.cancel()
            generator.finishAllRequests()
            return
        }
        XCTAssertFalse(thirdRequestFinished.value)
        XCTAssertEqual(generator.activeGenerationCount, 2)
        XCTAssertEqual(generator.maximumActiveGenerationCount, 2)

        generator.finishNextRequest()
        await allowPendingTasksToRegister()
        XCTAssertFalse(thirdRequestFinished.value)

        generator.finishNextRequest()
        let thirdImage = await thirdRequest.value
        XCTAssertTrue(thirdImage === thumbnail)
        XCTAssertEqual(generator.activeGenerationCount, 0)
        await provider.shutdown()
    }

    func testRequestStartedBeforePurgeDoesNotRepopulateMemoryCache() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let item = try makeLibraryItem(for: url)
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(
            image: thumbnail
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero
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

    func testQuickLookProviderLimitsConcurrentGeneration() async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let items = (0..<4).map { index in
            replacingRoot(
                in: scannedItem,
                with: URL(
                    fileURLWithPath: "/tmp/ThumbnailConcurrency-\(index)"
                )
            )
        }
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 2
        )
        let requests = items.map { item in
            Task {
                await provider.thumbnail(
                    for: item,
                    size: ThumbnailExpectation.pointSize,
                    scale: ThumbnailExpectation.scale
                )
            }
        }

        guard await waitForGenerationCount(2, generator: generator) else {
            requests.forEach { $0.cancel() }
            generator.finishAllRequests()
            return
        }
        XCTAssertEqual(generator.activeGenerationCount, 2)
        XCTAssertEqual(generator.maximumActiveGenerationCount, 2)

        generator.finishNextRequest()
        guard await waitForGenerationCount(3, generator: generator) else {
            requests.forEach { $0.cancel() }
            generator.finishAllRequests()
            return
        }
        XCTAssertEqual(generator.activeGenerationCount, 2)

        generator.finishNextRequest()
        guard await waitForGenerationCount(4, generator: generator) else {
            requests.forEach { $0.cancel() }
            generator.finishAllRequests()
            return
        }
        XCTAssertEqual(generator.maximumActiveGenerationCount, 2)

        generator.finishAllRequests()
        for request in requests {
            let image = await request.value
            XCTAssertTrue(image === thumbnail)
        }
        XCTAssertEqual(generator.activeGenerationCount, 0)
        await provider.shutdown()
    }

    func testQueuedRequestsCoalesceAndCancellationDoesNotReleaseRunningSlot()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let runningItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailRunning")
        )
        let sharedQueuedItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailSharedQueued")
        )
        let discardedQueuedItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailDiscardedQueued")
        )
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 1
        )
        let runningRequest = Task {
            await provider.thumbnail(
                for: runningItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            runningRequest.cancel()
            return
        }

        let cancelledSharedWaiter = Task {
            await provider.thumbnail(
                for: sharedQueuedItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()
        let survivingSharedWaiter = Task {
            await provider.thumbnail(
                for: sharedQueuedItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()
        let discardedQueuedRequest = Task {
            await provider.thumbnail(
                for: discardedQueuedItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()

        cancelledSharedWaiter.cancel()
        discardedQueuedRequest.cancel()
        let cancelledSharedImage = await cancelledSharedWaiter.value
        let discardedQueuedImage = await discardedQueuedRequest.value
        XCTAssertNil(cancelledSharedImage)
        XCTAssertNil(discardedQueuedImage)
        XCTAssertEqual(generator.generationCount, 1)
        XCTAssertEqual(generator.cancellationCount, 0)

        runningRequest.cancel()
        let runningImage = await runningRequest.value
        XCTAssertNil(runningImage)
        await waitForCancellationCount(1, generator: generator)
        await allowPendingTasksToRegister()
        XCTAssertEqual(generator.generationCount, 1)
        XCTAssertEqual(generator.activeGenerationCount, 1)

        generator.finishNextRequest()
        guard await waitForGenerationCount(2, generator: generator) else {
            survivingSharedWaiter.cancel()
            generator.finishAllRequests()
            return
        }
        generator.finishNextRequest()
        let survivingSharedImage = await survivingSharedWaiter.value

        XCTAssertTrue(survivingSharedImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 2)
        XCTAssertEqual(generator.maximumActiveGenerationCount, 1)
        await provider.shutdown()
    }

    func testInvalidatingRootDiscardsItsQueuedRequestWithoutGeneration()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let runningItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailInvalidationRunning")
        )
        let invalidatedRootURL = URL(
            fileURLWithPath: "/tmp/ThumbnailInvalidationQueued"
        )
        let invalidatedItem = replacingRoot(
            in: scannedItem,
            with: invalidatedRootURL
        )
        let survivingItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailInvalidationSurviving")
        )
        let thumbnail = try makeTestThumbnail()
        let generator = BlockingQuickLookThumbnailGenerator(image: thumbnail)
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 1
        )
        let runningRequest = Task {
            await provider.thumbnail(
                for: runningItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            runningRequest.cancel()
            return
        }
        let invalidatedRequest = Task {
            await provider.thumbnail(
                for: invalidatedItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()
        let survivingRequest = Task {
            await provider.thumbnail(
                for: survivingItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()

        await provider.invalidateThumbnails(
            forRootID: MediaLibraryRoot.ID(
                standardizedPath: invalidatedRootURL.path
            )
        )
        let invalidatedImage = await invalidatedRequest.value
        XCTAssertNil(invalidatedImage)
        XCTAssertEqual(generator.generationCount, 1)
        XCTAssertEqual(generator.cancellationCount, 0)

        generator.finishNextRequest()
        guard await waitForGenerationCount(2, generator: generator) else {
            runningRequest.cancel()
            survivingRequest.cancel()
            generator.finishAllRequests()
            return
        }
        generator.finishNextRequest()
        let runningImage = await runningRequest.value
        let survivingImage = await survivingRequest.value

        XCTAssertTrue(runningImage === thumbnail)
        XCTAssertTrue(survivingImage === thumbnail)
        XCTAssertEqual(generator.generationCount, 2)
        await provider.shutdown()
    }

    func testShutdownDiscardsQueuedRequestAndDrainsRunningGeneration()
        async throws {
        let url = try TestMediaFixture.h264URL(for: Self.self)
        let scannedItem = try makeLibraryItem(for: url)
        let runningItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailShutdownRunning")
        )
        let queuedItem = replacingRoot(
            in: scannedItem,
            with: URL(fileURLWithPath: "/tmp/ThumbnailShutdownQueued")
        )
        let generator = BlockingQuickLookThumbnailGenerator(
            image: try makeTestThumbnail()
        )
        let provider = QuickLookMediaThumbnailProvider(
            generator: generator,
            cacheMissDelay: .zero,
            maximumConcurrentRequestCount: 1
        )
        let runningRequest = Task {
            await provider.thumbnail(
                for: runningItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        guard await waitForGenerationCount(1, generator: generator) else {
            runningRequest.cancel()
            return
        }
        let queuedRequest = Task {
            await provider.thumbnail(
                for: queuedItem,
                size: ThumbnailExpectation.pointSize,
                scale: ThumbnailExpectation.scale
            )
        }
        await allowPendingTasksToRegister()

        let shutdownFinished = TestFlag()
        let shutdown = Task {
            await provider.shutdown()
            shutdownFinished.value = true
        }
        await waitForCancellationCount(1, generator: generator)
        let queuedImage = await queuedRequest.value

        XCTAssertNil(queuedImage)
        XCTAssertFalse(shutdownFinished.value)
        XCTAssertEqual(generator.generationCount, 1)

        generator.finishNextRequest()
        await shutdown.value
        let runningImage = await runningRequest.value

        XCTAssertNil(runningImage)
        XCTAssertTrue(shutdownFinished.value)
        XCTAssertEqual(generator.generationCount, 1)
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

    func testSupersededAttachmentCannotDisconnectNewerSameSurfaceAttachment()
        async throws
    {
        let engine = AVFoundationPlaybackEngine()
        let surface = TestAVPlayerSurface(id: .player)
        defer { engine.stop() }

        _ = try await engine.load(
            ResolvedMediaSource(
                url: try TestMediaFixture.h264URL(for: Self.self),
                displayName: "Sample"
            )
        )
        surface.isReadyForDisplay = false

        let firstAttachment = Task {
            try await engine.attach(to: surface)
        }
        for _ in 0..<1_000 where !surface.isConnected {
            await Task.yield()
        }
        guard surface.isConnected else {
            firstAttachment.cancel()
            XCTFail("The first attachment never connected its surface")
            return
        }

        let newerAttachment = Task {
            try await engine.attach(to: surface)
        }

        do {
            try await firstAttachment.value
            XCTFail("Expected the older attachment to be superseded")
        } catch let error as PlaybackEngineError {
            XCTAssertEqual(error, .superseded)
        }

        surface.isReadyForDisplay = true
        try await newerAttachment.value

        XCTAssertTrue(surface.isConnected)
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

    private func replacingRoot(
        in item: LibraryMediaItem,
        with rootURL: URL
    ) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: rootURL,
            rootName: rootURL.lastPathComponent,
            url: item.url,
            displayName: item.displayName,
            relativePath: item.relativePath,
            relativeDirectory: item.relativeDirectory,
            creationDate: item.creationDate,
            modificationDate: item.modificationDate,
            fileSize: item.fileSize
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

    private func waitForPlaybackProgress(
        _ expectedProgress: TimeInterval,
        latestProgress: () -> TimeInterval?
    ) async -> Bool {
        for _ in 0..<PlaybackExpectation.pollAttempts {
            if let progress = latestProgress(),
               abs(progress - expectedProgress)
                <= PlaybackExpectation.seekAccuracy {
                return true
            }
            try? await Task.sleep(
                nanoseconds: PlaybackExpectation.pollIntervalNanoseconds
            )
        }
        return false
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

    private func waitForCacheMissCount(
        _ expectedCount: Int,
        gate: FirstCacheMissGate
    ) async -> Bool {
        for _ in 0..<100 where gate.waitCount < expectedCount {
            await Task.yield()
        }
        XCTAssertEqual(gate.waitCount, expectedCount)
        return gate.waitCount == expectedCount
    }

    private func waitForDrainDeadlineCount(
        _ expectedCount: Int,
        gate: DrainDeadlineGate
    ) async -> Bool {
        for _ in 0..<100 where gate.waitCount < expectedCount {
            await Task.yield()
        }
        XCTAssertEqual(gate.waitCount, expectedCount)
        return gate.waitCount == expectedCount
    }

    private func allowPendingTasksToRegister() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

@MainActor
private final class TestFlag {
    var value = false
}

@MainActor
private final class FirstCacheMissGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var waitCount = 0

    func wait(for _: Duration) async throws {
        waitCount += 1
        guard waitCount == 1 else {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DrainDeadlineGate {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var requestedDeadlines: [Duration] = []

    var waitCount: Int {
        requestedDeadlines.count
    }

    func wait(for deadline: Duration) async throws {
        requestedDeadlines.append(deadline)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func openNext() {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume()
    }
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
    private(set) var activeGenerationCount = 0
    private(set) var maximumActiveGenerationCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func generateImage(
        for request: QLThumbnailGenerator.Request
    ) async throws -> CGImage {
        generationCount += 1
        activeGenerationCount += 1
        maximumActiveGenerationCount = max(
            maximumActiveGenerationCount,
            activeGenerationCount
        )
        defer {
            activeGenerationCount -= 1
        }
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

    func finishAllRequests() {
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { continuation in
            continuation.resume(returning: image)
        }
    }
}
