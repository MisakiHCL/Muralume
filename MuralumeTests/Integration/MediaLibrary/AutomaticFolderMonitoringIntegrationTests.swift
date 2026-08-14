import Combine
import Foundation
import XCTest
@testable import Muralume

@MainActor
final class AutomaticFolderMonitoringIntegrationTests: XCTestCase {
    private enum TestPolicy {
        static let debounceNanoseconds: UInt64 = 20_000_000
        static let pollNanoseconds: UInt64 = 20_000_000
        static let pollAttempts = 300
    }

    func testFSEventsRefreshesLibraryAfterNestedVideoIsAdded() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let playback = PlaybackCoordinator(engine: TestPlaybackEngine())
        let session = TestMediaAccessSession()
        session.restoredURLs = [rootURL]
        let coordinator = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: TestMediaSourceSelector(selections: []),
            mediaSession: session,
            scanner: FileSystemMediaLibraryScanner(),
            mediaThumbnailProvider: TestMediaThumbnailProvider(),
            playbackOrder: .ordered
        )
        let controller = MediaLibraryAutomaticRefreshController(
            monitor: FSEventsMediaLibraryChangeMonitor(),
            target: coordinator,
            debounceNanoseconds: TestPolicy.debounceNanoseconds
        )
        let bridge = AutomaticMonitoringPublisherBridge(
            library: coordinator,
            controller: controller
        )
        _ = bridge
        controller.start(folderURLs: coordinator.monitoredFolderURLs)

        let start = coordinator.start()
        _ = await coordinator.waitForStartupScan(after: start)
        XCTAssertEqual(coordinator.scanState, .ready)
        XCTAssertTrue(coordinator.items.isEmpty)

        let nestedDirectoryURL = rootURL.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedDirectoryURL,
            withIntermediateDirectories: true
        )
        let videoURL = nestedDirectoryURL.appendingPathComponent("Sky.mp4")
        try Data([0x00]).write(to: videoURL)

        await waitUntil {
            coordinator.items.map(\.url).contains(
                videoURL.standardizedFileURL
            )
        }
        XCTAssertEqual(
            coordinator.items.map(\.url),
            [videoURL.standardizedFileURL]
        )

        controller.stop()
        await coordinator.shutdown()
    }

    func testReconciliationFindsVideoWhenEventMonitorStaysSilent()
        async throws
    {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let playback = PlaybackCoordinator(engine: TestPlaybackEngine())
        let session = TestMediaAccessSession()
        session.restoredURLs = [rootURL]
        let coordinator = MediaLibraryCoordinator(
            playback: playback,
            sourceSelector: TestMediaSourceSelector(selections: []),
            mediaSession: session,
            scanner: FileSystemMediaLibraryScanner(),
            mediaThumbnailProvider: TestMediaThumbnailProvider(),
            playbackOrder: .ordered
        )
        let controller = MediaLibraryAutomaticRefreshController(
            monitor: DisabledMediaLibraryChangeMonitor(),
            target: coordinator,
            debounceNanoseconds: TestPolicy.debounceNanoseconds,
            reconciliationNanoseconds: TestPolicy.debounceNanoseconds
        )
        let bridge = AutomaticMonitoringPublisherBridge(
            library: coordinator,
            controller: controller
        )
        _ = bridge
        controller.start(folderURLs: coordinator.monitoredFolderURLs)

        let start = coordinator.start()
        _ = await coordinator.waitForStartupScan(after: start)
        XCTAssertTrue(coordinator.items.isEmpty)

        let videoURL = rootURL.appendingPathComponent("Fallback.mp4")
        try Data([0x00]).write(to: videoURL)

        await waitUntil {
            coordinator.items.map(\.url).contains(
                videoURL.standardizedFileURL
            )
        }
        XCTAssertEqual(
            coordinator.items.map(\.url),
            [videoURL.standardizedFileURL]
        )

        controller.stop()
        await coordinator.shutdown()
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<TestPolicy.pollAttempts {
            if condition() {
                return
            }
            try? await Task.sleep(
                nanoseconds: TestPolicy.pollNanoseconds
            )
        }
        XCTFail("Timed out waiting for an automatic folder refresh")
    }
}

@MainActor
private final class AutomaticMonitoringPublisherBridge {
    private var tasks: [Task<Void, Never>] = []

    init(
        library: MediaLibraryCoordinator,
        controller: MediaLibraryAutomaticRefreshController
    ) {
        tasks.append(Task { @MainActor [weak controller] in
            for await folderURLs in library.$monitoredFolderURLs.values {
                guard !Task.isCancelled else { return }
                controller?.update(folderURLs: folderURLs)
            }
        })
        tasks.append(Task { @MainActor [weak controller] in
            for await scanState in library.$scanState.values {
                guard !Task.isCancelled else { return }
                controller?.scanStateDidChange(
                    isScanning: scanState == .scanning,
                    lastScanSucceeded: scanState == .ready
                )
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }
}
