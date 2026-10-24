import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class AVFoundationPlaybackLoadingTests: XCTestCase {
    func testTaskCancellationAndStopCancelRealAssetMetadataRequests()
        async throws {
        let firstLoader = BlockingPlaybackResourceLoader()
        let secondLoader = BlockingPlaybackResourceLoader()
        var loaders = [firstLoader, secondLoader]
        var assets: [AVURLAsset] = []
        let controller = AVFoundationAssetLoadController(assetFactory: { _ in
            let loader = loaders.removeFirst()
            let asset = AVURLAsset(url: URL(
                string: "muralume-blocked://metadata/\(UUID().uuidString).mp4"
            )!)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            assets.append(asset)
            return asset
        })
        let engine = AVFoundationPlaybackEngine(assetLoadController: controller)
        let first = Task { try await engine.load(source("first.mp4")) }
        guard await waitUntil({ firstLoader.requestCount > 0 }) else {
            first.cancel()
            engine.stop()
            return
        }
        first.cancel()
        await assertSuperseded(first)
        var firstDrained = false
        let firstDrain = Task {
            await engine.drainPendingWork()
            firstDrained = true
        }
        let didDrainFirst = await waitUntil({ firstDrained })
        if !didDrainFirst { assets[0].cancelLoading() }
        await firstDrain.value

        // A delayed cancellation callback for the first request must not
        // cancel a later asset belonging to the same engine.
        var secondFinished = false
        let second = Task {
            defer { secondFinished = true }
            return try await engine.load(source("second.mp4"))
        }
        guard await waitUntil({ secondLoader.requestCount > 0 }) else {
            second.cancel()
            engine.stop()
            return
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(secondFinished)
        engine.stop()
        await assertSuperseded(second)
        var secondDrained = false
        let secondDrain = Task {
            await engine.drainPendingWork()
            secondDrained = true
        }
        let didDrainSecond = await waitUntil({ secondDrained })
        if !didDrainSecond { assets[1].cancelLoading() }
        await secondDrain.value
    }

    func testCancelledWorkerKeepsItsSlotAndAliasUntilActualExit()
        async throws {
        let gate = BlockingPlaybackMetadataGate()
        var assetURLs: [URL] = []
        let controller = AVFoundationAssetLoadController(
            assetFactory: { url in
                assetURLs.append(url)
                return AVURLAsset(url: url)
            },
            metadataLoader: { _ in try await gate.wait() }
        )
        let engine = AVFoundationPlaybackEngine(assetLoadController: controller)
        var current = Task { try await engine.load(source("first.vob")) }
        guard await waitUntil({ gate.startedCount == 1 }) else {
            engine.stop()
            gate.finishAll()
            return
        }
        let aliasURL = try XCTUnwrap(assetURLs.first)
        XCTAssertNotEqual(aliasURL.path, source("first.vob").url.path)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))

        for index in 0..<100 {
            let old = current
            current = Task { try await engine.load(source("latest-\(index).mp4")) }
            await assertSuperseded(old)
        }
        XCTAssertEqual(assetURLs.count, 1)
        XCTAssertEqual(gate.startedCount, 1)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))

        gate.finishNext()
        guard await waitUntil({ gate.startedCount == 2 }) else {
            engine.stop()
            gate.finishAll()
            return
        }
        XCTAssertEqual(assetURLs.count, 2)
        XCTAssertEqual(assetURLs.last?.lastPathComponent, "latest-99.mp4")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))
        engine.stop()
        await assertSuperseded(current)
        var drainFinished = false
        let drain = Task {
            await engine.drainPendingWork()
            drainFinished = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(drainFinished)
        gate.finishNext()
        await drain.value
        XCTAssertTrue(drainFinished)
        XCTAssertEqual(gate.maximumActiveCount, 1)
    }

    func testPreCancelledLoadDoesNotInterruptCurrentEngineRequest()
        async throws {
        let gate = BlockingPlaybackMetadataGate()
        var assetURLs: [URL] = []
        let controller = AVFoundationAssetLoadController(
            assetFactory: { url in
                assetURLs.append(url)
                return AVURLAsset(url: url)
            },
            metadataLoader: { _ in try await gate.wait() }
        )
        let engine = AVFoundationPlaybackEngine(assetLoadController: controller)
        defer {
            engine.stop()
            gate.finishAll()
        }
        var currentFinished = false
        let current = Task {
            defer { currentFinished = true }
            return try await engine.load(source("current.mp4"))
        }
        guard await waitUntil({ gate.startedCount == 1 }) else {
            engine.stop()
            gate.finishAll()
            _ = try? await current.value
            await engine.drainPendingWork()
            return
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.load(source("already-cancelled.mp4"))
        }
        await assertSuperseded(cancelled)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(assetURLs, [source("current.mp4").url])
        XCTAssertEqual(gate.startedCount, 1)
        XCTAssertFalse(currentFinished)

        // Let the original request reach the metadata validation guard. Its
        // unsupported result proves that the cancelled caller did not advance
        // the engine generation, which would instead supersede this request.
        gate.finishNextUnsupportedAsset()
        do {
            _ = try await current.value
            XCTFail("The fixture has no playable video metadata")
        } catch let error as PlaybackEngineError {
            XCTAssertEqual(error, .unsupported)
        } catch {
            XCTFail("Unexpected original load error: \(error)")
        }
        XCTAssertTrue(currentFinished)
        engine.stop()
        gate.finishAll()
        await engine.drainPendingWork()
    }

    private func source(_ fileName: String) -> ResolvedMediaSource {
        ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/muralume-playback-loading/\(fileName)"),
            displayName: fileName
        )
    }

    private func assertSuperseded(
        _ task: Task<TimeInterval, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected a superseded load", file: file, line: line)
        } catch let error as PlaybackEngineError {
            XCTAssertEqual(error, .superseded, file: file, line: line)
        } catch {
            XCTFail("Unexpected load error: \(error)", file: file, line: line)
        }
    }

    @discardableResult
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Playback metadata operation did not reach the expected state")
        return false
    }
}

private final class BlockingPlaybackResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "MuralumeTests.BlockingPlaybackResourceLoader")
    private let lock = NSLock()
    private var requests: [AVAssetResourceLoadingRequest] = []

    var requestCount: Int { lock.withLock { requests.count } }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest:
            AVAssetResourceLoadingRequest
    ) -> Bool {
        lock.withLock { requests.append(loadingRequest) }
        return true
    }


}

@MainActor
private final class BlockingPlaybackMetadataGate {
    private var continuations: [
        CheckedContinuation<AVFoundationAssetMetadata, Error>
    ] = []
    private(set) var startedCount = 0
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func wait() async throws -> AVFoundationAssetMetadata {
        startedCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        return try await withCheckedThrowingContinuation {
            continuations.append($0)
        }
    }

    func finishNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(throwing: PlaybackEngineError.cannotOpen)
    }

    func finishNextUnsupportedAsset() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: AVFoundationAssetMetadata(
            isPlayable: false,
            duration: .zero,
            videoTracks: [],
            audioGroup: nil,
            subtitleGroup: nil
        ))
    }

    func finishAll() {
        while !continuations.isEmpty { finishNext() }
    }
}
