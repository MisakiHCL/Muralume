import AVFoundation
import XCTest
@testable import Muralume

@MainActor
final class VideoInformationLoadingTests: XCTestCase {
    func testCancellationStops32RealMetadataRequestsAndReleasesAssets()
        async throws {
        for sameURL in [false, true] {
            let registry = InformationAssetRegistry(blockResources: true)
            let loader = AVAssetVideoInformationLoader(
                assetFactory: { registry.makeAsset(for: $0) }
            )
            for index in 0..<32 {
                let task = Task {
                    try await loader.information(for: source(
                        "\(sameURL ? 0 : index).mp4"
                    ))
                }
                guard await waitUntil({ registry.startedCount > index }) else {
                    task.cancel()
                    registry.cancelAll()
                    _ = try? await task.value
                    await loader.drainPendingWork()
                    return
                }
                task.cancel()
                await assertCancelled(task)
                // Real AVFoundation cancellation must unwind without a test
                // calling cancelLoading() or completing resource requests.
                let released = await waitUntil({ registry.liveCount == 0 })
                if !released { registry.cancelAll() }
                await loader.drainPendingWork()
                XCTAssertEqual(registry.createdCount, index + 1)
                XCTAssertEqual(registry.liveCount, 0)
            }
            XCTAssertEqual(registry.startedCount, 32)
        }
    }

    func testSupersededWorkerKeepsSlotAndAliasUntilActualExit() async throws {
        let gate = InformationMetadataGate()
        let registry = InformationAssetRegistry()
        let loader = AVAssetVideoInformationLoader(
            assetFactory: { registry.makeAsset(for: $0) },
            metadataLoader: { _, _ in await gate.wait() }
        )
        var current = Task {
            try await loader.information(for: source("first.f4v"))
        }
        guard await waitUntil({ await gate.startedCount == 1 }) else {
            current.cancel()
            await gate.finishAll()
            return
        }
        let aliasURL = try XCTUnwrap(registry.urls.first)
        XCTAssertEqual(aliasURL.pathExtension, "mp4")
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))

        for index in 0..<100 {
            let old = current
            current = Task {
                try await loader.information(for: source("latest-\(index).mp4"))
            }
            await assertCancelled(old)
            // Repeated old-task cancellation callbacks cannot affect the
            // newest pending request, even if their actor delivery is late.
            old.cancel()
        }
        XCTAssertEqual(registry.createdCount, 1)
        let before = await gate.startedCount
        XCTAssertEqual(before, 1)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))

        await gate.finishNext()
        guard await waitUntil({ await gate.startedCount == 2 }) else {
            current.cancel()
            await gate.finishAll()
            return
        }
        XCTAssertEqual(registry.createdCount, 2)
        XCTAssertEqual(registry.urls.last?.lastPathComponent, "latest-99.mp4")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(
            atPath: aliasURL.path
        ))
        current.cancel()
        await assertCancelled(current)
        var drained = false
        let drain = Task {
            await loader.drainPendingWork()
            drained = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(drained)
        await gate.finishNext()
        await drain.value
        let maximum = await gate.maximumActiveCount
        XCTAssertEqual(maximum, 1)
        let released = await waitUntil({ registry.liveCount == 0 })
        XCTAssertTrue(released)
    }

    func testPreCancelledRequestDoesNotInterruptCurrentRequest() async throws {
        let gate = InformationMetadataGate()
        let registry = InformationAssetRegistry()
        let loader = AVAssetVideoInformationLoader(
            assetFactory: { registry.makeAsset(for: $0) },
            metadataLoader: { _, _ in await gate.wait() }
        )
        let current = Task {
            try await loader.information(for: source("current.mp4"))
        }
        guard await waitUntil({ await gate.startedCount == 1 }) else {
            current.cancel()
            await gate.finishAll()
            return
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.information(for: source("cancelled.mp4"))
        }
        await assertCancelled(cancelled)
        XCTAssertEqual(registry.createdCount, 1)
        await gate.finishNext()
        let information = try await current.value
        XCTAssertEqual(information, InformationMetadataGate.information)
        await loader.drainPendingWork()
    }

    func testPreCancelledAndDelayedCancellationPreserveLatestSameURLRequest()
        async throws {
        let gate = InformationMetadataGate()
        let registry = InformationAssetRegistry()
        let loader = AVAssetVideoInformationLoader(
            assetFactory: { registry.makeAsset(for: $0) },
            metadataLoader: { _, _ in await gate.wait() }
        )
        let old = Task {
            try await loader.information(for: source("same.mp4"))
        }
        guard await waitUntil({ await gate.startedCount == 1 }) else {
            old.cancel()
            await gate.finishAll()
            return
        }
        let latest = Task {
            try await loader.information(for: source("same.mp4"))
        }
        await assertCancelled(old)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.information(for: source("cancelled.mp4"))
        }
        await assertCancelled(cancelled)
        old.cancel()
        await gate.finishNext()
        guard await waitUntil({ await gate.startedCount == 2 }) else {
            latest.cancel()
            await gate.finishAll()
            return
        }
        old.cancel()
        for _ in 0..<20 { await Task.yield() }
        await gate.finishNext()
        let information = try await latest.value
        XCTAssertEqual(information, InformationMetadataGate.information)
        XCTAssertEqual(registry.createdCount, 2)
        await loader.drainPendingWork()
    }

    private func source(_ name: String) -> ResolvedMediaSource {
        ResolvedMediaSource(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("MuralumeInformationLoadingTests")
                .appendingPathComponent(name),
            displayName: name
        )
    }

    private func assertCancelled(
        _ task: Task<VideoInformation, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancelled metadata loading", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected metadata error: \(error)", file: file, line: line)
        }
    }

    @discardableResult
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Information loading did not reach the expected state")
        return false
    }
}

private final class InformationAssetRegistry: @unchecked Sendable {
    private struct Record {
        let url: URL
        weak var asset: AVURLAsset?
        let transport: InformationBlockingTransport?
    }

    private let lock = NSLock()
    private let blockResources: Bool
    private var records: [Record] = []

    init(blockResources: Bool = false) {
        self.blockResources = blockResources
    }

    func makeAsset(for url: URL) -> AVURLAsset {
        let asset: AVURLAsset
        let transport: InformationBlockingTransport?
        if blockResources {
            asset = AVURLAsset(url: URL(
                string: "muralume-information-blocked://metadata/\(url.lastPathComponent)"
            )!)
            let blocker = InformationBlockingTransport()
            asset.resourceLoader.setDelegate(blocker, queue: blocker.queue)
            transport = blocker
        } else {
            asset = AVURLAsset(url: url)
            transport = nil
        }
        lock.withLock {
            records.append(Record(url: url, asset: asset, transport: transport))
        }
        return asset
    }

    var urls: [URL] { lock.withLock { records.map(\.url) } }
    var createdCount: Int { lock.withLock { records.count } }
    var liveCount: Int {
        lock.withLock { records.filter { $0.asset != nil }.count }
    }
    var startedCount: Int {
        lock.withLock { records.filter { $0.transport?.didStart == true }.count }
    }
    var cancelledResourceCount: Int {
        lock.withLock { records.reduce(0) { $0 + ($1.transport?.cancelCount ?? 0) } }
    }

    func cancelAll() {
        let assets = lock.withLock { records.compactMap(\.asset) }
        assets.forEach { $0.cancelLoading() }
    }
}

private final class InformationBlockingTransport: NSObject,
    AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "MuralumeTests.InformationBlockingTransport")
    private let lock = NSLock()
    private var starts = 0
    private var cancellations = 0

    var didStart: Bool { lock.withLock { starts > 0 } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest:
            AVAssetResourceLoadingRequest
    ) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.withLock { cancellations += 1 }
    }
}

private actor InformationMetadataGate {
    private var continuations: [CheckedContinuation<VideoInformation, Never>] = []
    private(set) var startedCount = 0
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    static let information = VideoInformation(
        container: "MPEG-4", videoCodecs: ["H.264 / AVC"],
        resolution: VideoResolution(width: 320, height: 180), duration: 20,
        frameRate: 15, videoBitRate: 63_000, dynamicRange: .unknown,
        colorSpace: nil, audioCodecs: [], audioTrackCount: 0,
        subtitleTrackCount: 0, fileSize: 158_219
    )

    func wait() async -> VideoInformation {
        startedCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        return await withCheckedContinuation { continuations.append($0) }
    }

    func finishNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: Self.information)
    }

    func finishAll() {
        while !continuations.isEmpty { finishNext() }
    }
}
