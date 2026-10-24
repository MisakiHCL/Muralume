import Foundation
import XCTest
@testable import Muralume

final class DesktopMediaSearchTests: XCTestCase {
    func testSearchPreservesThreeDesktopFieldsAndLocalizedMatching() throws {
        let name = makeItem(
            name: "Résumé 02", path: "CV.mov", rootName: "Archive"
        )
        let root = makeItem(
            name: "Clouds", path: "Clouds.mov", rootName: "SKY LIBRARY"
        )
        let directory = makeItem(
            name: "Evening", path: "Northern Lights/Aurora.mov"
        )
        let hiddenFilename = makeItem(
            name: "Morning", path: "Tokyo 10.mov", rootName: "Archive"
        )
        let items = [root, hiddenFilename, directory, name]
        for (query, expected) in [
            ("  resume 02 \n", [name]),
            ("sky library", [root]),
            ("northern lights", [directory]),
            ("tokyo 10", [])
        ] {
            XCTAssertEqual(
                try DesktopMediaSearch(query: query)
                    .filteredItemsCancellable(from: items),
                expected,
                "Desktop search must keep its original three fields"
            )
        }
    }

    func testWhitespaceAndChineseQueriesKeepOriginalOrder() throws {
        let first = makeItem(name: "不在场", path: "电影/First.mov")
        let second = makeItem(name: "在路上", path: "旅行/Second.mov")
        let other = makeItem(name: "Ocean", path: "Ocean.mov")
        let items = [second, other, first]
        XCTAssertEqual(
            try DesktopMediaSearch(query: " \n\t\u{3000}")
                .filteredItemsCancellable(from: items),
            items
        )
        XCTAssertEqual(
            try DesktopMediaSearch(query: "\u{3000}在\u{3000}")
                .filteredItemsCancellable(from: items),
            [second, first]
        )
    }

    func testFilteringMatchesLegacyDesktopPredicateAcrossQueries() throws {
        let items = (0..<2_000).map { index in
            makeItem(
                name: index.isMultiple(of: 3) ? "Résumé \(index)" : "视频 \(index)",
                path: index.isMultiple(of: 2)
                    ? "Travel/Clip-\(index).mov" : "Night/Clip-\(index).mov",
                rootName: index.isMultiple(of: 7) ? "SKY LIBRARY" : "Archive"
            )
        }
        for rawQuery in ["", " \n", "resume", "视频", "SKY", " travel ", "Night", "Clip-", "missing"] {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = query.isEmpty ? items : items.filter {
                $0.displayName.localizedStandardContains(query)
                    || $0.rootName.localizedStandardContains(query)
                    || $0.relativeDirectory.localizedStandardContains(query)
            }
            XCTAssertEqual(
                try DesktopMediaSearch(query: rawQuery)
                    .filteredItemsCancellable(from: items),
                expected
            )
        }
    }

    func testCancelledSearchStopsBeforeScanning() async {
        let item = makeItem(name: "Clouds", path: "Clouds.mov")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DesktopMediaSearch(query: "Clouds")
                .filteredItemsCancellable(from: Array(repeating: item, count: 10_000))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled search must not produce a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testDesktopRequestsRunOneActualWorkerAndKeepLatestOrderedSnapshot() async {
        let controller = LatestMediaSearch<[LibraryMediaItem]>()
        let gate = DesktopSearchGate()
        let first = makeItem(name: "Sky First", path: "First.mov")
        let last = makeItem(name: "Sky Last", path: "Last.mov")
        let query = DesktopMediaSearch(query: " sky ")
        let firstKey = requestID(revision: 0, query: query.query)
        controller.request(key: firstKey) {
            await gate.start(0, isMainThread: Self.isMainThreadSnapshot())
            await gate.suspend()
            await gate.finish()
            return [first, last] // Deliberately ignores cancellation.
        }
        await gate.waitUntilSuspended()
        for revision in 1...100 {
            let key = requestID(revision: UInt64(revision), query: query.query)
            controller.request(key: key) {
                await gate.start(revision, isMainThread: Self.isMainThreadSnapshot())
                let result = try query.filteredItemsCancellable(from: [last, first])
                await gate.finish()
                return result
            }
        }
        let beforeRelease = await gate.snapshot()
        XCTAssertEqual(beforeRelease.starts, [0])
        XCTAssertEqual(beforeRelease.maximumActive, 1)
        await gate.release()
        await controller.waitForPendingSearch()
        let completed = await gate.snapshot()
        XCTAssertEqual(completed.starts, [0, 100])
        XCTAssertEqual(completed.maximumActive, 1)
        XCTAssertFalse(completed.ranOnMainThread)
        XCTAssertNil(controller.result(for: firstKey))
        let latestKey = requestID(revision: 100, query: query.query)
        XCTAssertEqual(controller.result(for: latestKey), [last, first])
        XCTAssertNil(controller.result(for: requestID(
            revision: 100, query: query.query, locale: "zh_CN"
        )))
        controller.cancel()
        XCTAssertNil(controller.result(for: latestKey))
    }

    @MainActor
    func testClosingPickerDropsPendingRequestsAndCancelledResults() async {
        let controller = LatestMediaSearch<[LibraryMediaItem]>()
        let gate = DesktopSearchGate()
        let item = makeItem(name: "Sky", path: "Sky.mov")
        let firstKey = requestID(revision: 1, query: "sky")
        let nextKey = requestID(revision: 2, query: "sky")
        controller.request(key: firstKey) {
            await gate.start(1, isMainThread: Self.isMainThreadSnapshot())
            await gate.suspend()
            await gate.finish()
            return [item]
        }
        await gate.waitUntilSuspended()
        controller.request(key: nextKey) {
            await gate.start(2, isMainThread: Self.isMainThreadSnapshot())
            await gate.finish()
            return [item]
        }
        controller.cancel()
        await gate.release()
        await controller.waitForPendingSearch()
        let completed = await gate.snapshot()
        XCTAssertEqual(completed.starts, [1])
        XCTAssertNil(controller.result(for: firstKey))
        XCTAssertNil(controller.result(for: nextKey))
    }

    @MainActor
    func testPreCancelledPickerTaskCannotReplaceOrClearCurrentSearch() async {
        let controller = LatestMediaSearch<[LibraryMediaItem]>()
        let gate = DesktopSearchGate()
        let item = makeItem(name: "Sky", path: "Sky.mov")
        let currentKey = requestID(revision: 1, query: "sky")
        controller.request(key: currentKey) {
            await gate.start(1, isMainThread: Self.isMainThreadSnapshot())
            await gate.suspend()
            await gate.finish()
            return [item]
        }
        await gate.waitUntilSuspended()
        let staleKey = requestID(revision: 2, query: "other")
        let stale = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            DesktopMediaSearch(query: "other").updateProjection(
                controller, requestID: staleKey, items: [item]
            )
            DesktopMediaSearch(query: "").updateProjection(
                controller, requestID: staleKey, items: []
            )
        }
        await stale.value
        await gate.release()
        await controller.waitForPendingSearch()
        XCTAssertEqual(controller.result(for: currentKey), [item])
        XCTAssertNil(controller.result(for: staleKey))
        let completed = await gate.snapshot()
        XCTAssertEqual(completed.starts, [1])
        controller.cancel()
    }

    @MainActor
    func testSystemLocaleChangeInvalidatesResultWithFixedAppLocale() async {
        let controller = LatestMediaSearch<[LibraryMediaItem]>()
        let item = makeItem(name: "Sky", path: "Sky.mov")
        let search = DesktopMediaSearch(query: "sky")
        let originalKey = requestID(
            revision: 1, query: search.query, systemLocale: "en_US"
        )
        search.updateProjection(controller, requestID: originalKey, items: [item])
        await controller.waitForPendingSearch()
        XCTAssertEqual(controller.result(for: originalKey), [item])
        let changedKey = requestID(
            revision: 1, query: search.query, systemLocale: "tr_TR"
        )
        XCTAssertEqual(originalKey.localeIdentifier, changedKey.localeIdentifier)
        XCTAssertNotEqual(originalKey, changedKey)
        XCTAssertNil(controller.result(for: changedKey))
        search.updateProjection(controller, requestID: changedKey, items: [])
        await controller.waitForPendingSearch()
        XCTAssertEqual(controller.result(for: changedKey), [])
        XCTAssertNil(controller.result(for: originalKey))
        controller.cancel()
    }

    private nonisolated static func isMainThreadSnapshot() -> Bool {
        Thread.isMainThread
    }

    private func requestID(
        revision: UInt64,
        query: String,
        locale: String = "en_US",
        systemLocale: String = "en_US"
    ) -> DesktopMediaSearchRequestID {
        DesktopMediaSearchRequestID(
            itemsRevision: revision, query: query, localeIdentifier: locale,
            systemLocaleIdentifier: systemLocale
        )
    }

    private func makeItem(
        name: String,
        path: String,
        rootName: String = "Library"
    ) -> LibraryMediaItem {
        let root = URL(fileURLWithPath: "/Library")
        return LibraryMediaItem(
            rootURL: root,
            rootName: rootName,
            url: root.appendingPathComponent(path),
            displayName: name,
            relativePath: path,
            relativeDirectory: (path as NSString).deletingLastPathComponent,
            creationDate: nil,
            fileSize: 1
        )
    }
}

private actor DesktopSearchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var starts: [Int] = []
    private var active = 0
    private var maximumActive = 0
    private var ranOnMainThread = false

    func start(_ value: Int, isMainThread: Bool) {
        starts.append(value)
        active += 1
        maximumActive = max(maximumActive, active)
        ranOnMainThread = ranOnMainThread || isMainThread
    }

    func finish() {
        active -= 1
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func snapshot() -> (
        starts: [Int], maximumActive: Int, ranOnMainThread: Bool
    ) {
        (starts, maximumActive, ranOnMainThread)
    }
}
