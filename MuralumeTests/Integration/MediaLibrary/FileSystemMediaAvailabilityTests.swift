import Foundation
import XCTest
@testable import Muralume

@MainActor
final class FileSystemMediaAvailabilityTests: XCTestCase {
    func testAvailabilityRequiresReadableParentToConfirmMissingFile()
        async throws
    {
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let existingItem = makeItem(
            url: sandboxURL.appendingPathComponent("Existing.mov")
        )
        try Data([0xA5]).write(to: existingItem.url)
        let missingItem = makeItem(
            url: sandboxURL.appendingPathComponent("Missing.mov")
        )
        let unavailableItem = makeItem(
            url: sandboxURL
                .appendingPathComponent("Offline", isDirectory: true)
                .appendingPathComponent("Unknown.mov")
        )
        let scanner = FileSystemMediaLibraryScanner()
        let existingAvailability = await scanner.availability(of: existingItem)
        let missingAvailability = await scanner.availability(of: missingItem)
        let unavailableAvailability = await scanner.availability(
            of: unavailableItem
        )

        XCTAssertEqual(existingAvailability, .available)
        XCTAssertEqual(missingAvailability, .missing)
        XCTAssertEqual(unavailableAvailability, .temporarilyUnavailable)
    }

    func testAvailabilityNeverConfirmsMissingFileAfterBudgetExpires()
        async throws
    {
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let missingItem = makeItem(
            url: sandboxURL.appendingPathComponent("Missing.mov")
        )
        let scanner = FileSystemMediaLibraryScanner(
            scanLimits: FileSystemMediaLibraryScanLimits(
                maximumDuration: .zero,
                maximumEstimatedWorkingSetBytes: 1_024
            )
        )

        let availability = await scanner.availability(of: missingItem)

        XCTAssertEqual(availability, .temporarilyUnavailable)
    }

    func testAvailabilityNeverConfirmsMissingFileAfterCancellation()
        async throws
    {
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let missingItem = makeItem(
            url: sandboxURL.appendingPathComponent("Missing.mov")
        )
        let scanner = FileSystemMediaLibraryScanner()
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return await scanner.availability(of: missingItem)
        }

        let availability = await task.value

        XCTAssertEqual(availability, .temporarilyUnavailable)
    }

    func testAvailabilityFindsHiddenDanglingSymlinkWithoutReadingItsTarget()
        async throws
    {
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let item = makeItem(
            url: sandboxURL.appendingPathComponent(".Hidden.mov")
        )
        try FileManager.default.createSymbolicLink(
            at: item.url,
            withDestinationURL: sandboxURL.appendingPathComponent("Offline.mov")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))

        let availability = await FileSystemMediaLibraryScanner().availability(
            of: item
        )

        XCTAssertEqual(availability, .available)
    }

    private func makeSandbox() throws -> URL {
        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        return sandboxURL
    }

    private func makeItem(url: URL) -> LibraryMediaItem {
        LibraryMediaItem(
            rootURL: url.deletingLastPathComponent(),
            rootName: "Library",
            url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            relativePath: url.lastPathComponent,
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
    }
}
