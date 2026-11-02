import Foundation
import XCTest
@testable import Muralume

final class SubtitleFontFamilyLoaderTests: XCTestCase {
    private enum Timeout {
        static let expectation: TimeInterval = 2
        static let blockedEnumeration: TimeInterval = 5
    }

    @MainActor
    func testEnumeratesFontFamiliesOffMainThreadWhenRequestedByUI() async {
        let families = await SubtitleFontFamilyLoader.load {
            XCTAssertFalse(
                Thread.isMainThread,
                "Opening subtitle settings must not enumerate fonts on the UI thread"
            )
            return ["Font 2"]
        }

        XCTAssertEqual(families, ["Font 2"])
    }

    func testMainActorRemainsResponsiveWhileEnumerationIsBlocked() async {
        let started = XCTestExpectation(description: "Font enumeration started")
        let mainActorResponded = XCTestExpectation(description: "Main actor responded")
        let gate = DispatchSemaphore(value: 0)
        let loadTask = Task { @MainActor in
            await SubtitleFontFamilyLoader.load {
                started.fulfill()
                XCTAssertEqual(
                    gate.wait(timeout: .now() + Timeout.blockedEnumeration),
                    .success,
                    "The test must release its blocked font enumeration"
                )
                return ["Font 2"]
            }
        }
        defer {
            gate.signal()
            loadTask.cancel()
        }

        let startResult = await XCTWaiter.fulfillment(
            of: [started], timeout: Timeout.expectation
        )
        XCTAssertEqual(startResult, .completed)

        let responseTask = Task { @MainActor in
            mainActorResponded.fulfill()
        }
        let responseResult = await XCTWaiter.fulfillment(
            of: [mainActorResponded], timeout: Timeout.expectation
        )
        XCTAssertEqual(
            responseResult,
            .completed,
            "The settings UI must remain responsive before font enumeration finishes"
        )

        gate.signal()
        let families = await loadTask.value
        await responseTask.value
        XCTAssertEqual(families, ["Font 2"])
    }

    func testCancellationDiscardsFamiliesReturnedAfterSettingsClose() async {
        let started = XCTestExpectation(description: "Font enumeration started")
        let returned = XCTestExpectation(description: "Font enumeration returned")
        let gate = DispatchSemaphore(value: 0)
        let loadTask = Task { @MainActor in
            await SubtitleFontFamilyLoader.load {
                started.fulfill()
                XCTAssertEqual(
                    gate.wait(timeout: .now() + Timeout.blockedEnumeration),
                    .success,
                    "The test must release its blocked font enumeration"
                )
                returned.fulfill()
                // A native font query can finish after cancellation without
                // observing it. Its late result must still be discarded.
                return ["Late Font"]
            }
        }
        defer {
            gate.signal()
            loadTask.cancel()
        }

        let startResult = await XCTWaiter.fulfillment(
            of: [started], timeout: Timeout.expectation
        )
        XCTAssertEqual(startResult, .completed)

        loadTask.cancel()
        gate.signal()
        let families = await loadTask.value
        let returnResult = await XCTWaiter.fulfillment(
            of: [returned], timeout: Timeout.expectation
        )

        XCTAssertEqual(returnResult, .completed)
        XCTAssertNil(families, "Closing settings must not publish a late font directory")
    }

    func testFiltersInvalidNamesDeduplicatesAndUsesNaturalOrdering() async {
        let maximumLength = SubtitleAppearancePreferences.maximumFontFamilyNameLength
        let boundaryName = String(repeating: "Z", count: maximumLength)
        let oversizedName = String(repeating: "Z", count: maximumLength + 1)

        let families = await SubtitleFontFamilyLoader.load {
            [
                "Font 10", "", " \n\t", "\u{3000}", "Font 2",
                "Font 10", oversizedName, boundaryName, "Font 2"
            ]
        }

        XCTAssertEqual(families, ["Font 2", "Font 10", boundaryName])
    }
}
