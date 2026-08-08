import Foundation
import XCTest
@testable import Muralume

@MainActor
final class FileSystemMediaLibraryScannerTests: XCTestCase {
    func testScansNestedFilesAcrossMultipleRootsInStablePathOrder() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let firstRootURL = sandboxURL.appendingPathComponent(
            "First Root",
            isDirectory: true
        )
        let secondRootURL = sandboxURL.appendingPathComponent(
            "Second Root",
            isDirectory: true
        )
        let nestedDirectoryURL = firstRootURL
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("Deep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondRootURL,
            withIntermediateDirectories: true
        )

        let topLevelURL = firstRootURL.appendingPathComponent("Bravo.mov")
        let nestedURL = nestedDirectoryURL.appendingPathComponent("Alpha.MP4")
        let secondRootMediaURL = secondRootURL.appendingPathComponent("Zulu.m4v")
        try writeFile(at: topLevelURL, byteCount: 4)
        try writeFile(at: nestedURL, byteCount: 12)
        try writeFile(at: secondRootMediaURL, byteCount: 8)

        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let modificationDate = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes(
            [
                .creationDate: creationDate,
                .modificationDate: modificationDate
            ],
            ofItemAtPath: nestedURL.path
        )

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [secondRootURL, firstRootURL, firstRootURL]
        )

        XCTAssertEqual(
            snapshot.roots.map(\.url),
            [firstRootURL, secondRootURL].map(\.standardizedFileURL)
        )
        XCTAssertEqual(
            snapshot.items.map(\.url),
            [topLevelURL, nestedURL, secondRootMediaURL]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )

        let nestedItem = try XCTUnwrap(
            snapshot.items.first { $0.url == nestedURL.standardizedFileURL }
        )
        XCTAssertEqual(nestedItem.rootURL, firstRootURL.standardizedFileURL)
        XCTAssertEqual(nestedItem.rootName, "First Root")
        XCTAssertEqual(nestedItem.displayName, "Alpha")
        XCTAssertEqual(nestedItem.relativePath, "Nested/Deep/Alpha.MP4")
        XCTAssertEqual(nestedItem.relativeDirectory, "Nested/Deep")
        XCTAssertEqual(nestedItem.fileSize, 12)
        XCTAssertEqual(
            try XCTUnwrap(nestedItem.creationDate).timeIntervalSince1970,
            creationDate.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(nestedItem.modificationDate).timeIntervalSince1970,
            modificationDate.timeIntervalSince1970,
            accuracy: 1
        )

        let repeatedSnapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [firstRootURL, secondRootURL]
        )
        XCTAssertEqual(snapshot, repeatedSnapshot)
    }

    func testSubsequentScanDiscoversVideoAddedToExistingFolder() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let existingURL = rootURL.appendingPathComponent("Existing.mov")
        let addedURL = rootURL.appendingPathComponent("Added.mp4")
        try writeFile(at: existingURL, byteCount: 1)
        let scanner = FileSystemMediaLibraryScanner()

        let initialSnapshot = try await scanner.scan(rootURLs: [rootURL])
        try writeFile(at: addedURL, byteCount: 2)
        let refreshedSnapshot = try await scanner.scan(rootURLs: [rootURL])

        XCTAssertEqual(
            initialSnapshot.items.map(\.url),
            [existingURL.standardizedFileURL]
        )
        XCTAssertEqual(
            refreshedSnapshot.items.map(\.url),
            [addedURL, existingURL]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
    }

    func testScansSingleFileAndMixedSourcesWithPartialUnsupportedInput() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let folderURL = sandboxURL.appendingPathComponent(
            "Folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let folderMediaURL = folderURL.appendingPathComponent("Folder.mov")
        let directMediaURL = sandboxURL.appendingPathComponent("Direct.mp4")
        let unsupportedURL = sandboxURL.appendingPathComponent("Notes.txt")
        try writeFile(at: folderMediaURL, byteCount: 2)
        try writeFile(at: directMediaURL, byteCount: 3)
        try writeFile(at: unsupportedURL, byteCount: 1)

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            sources: [
                MediaSource(url: directMediaURL, kind: .file),
                MediaSource(url: unsupportedURL, kind: .file),
                MediaSource(url: folderURL, kind: .folder)
            ]
        )

        XCTAssertEqual(
            snapshot.roots.map(\.url),
            [directMediaURL, folderURL]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
        XCTAssertEqual(
            snapshot.roots.map(\.kind),
            snapshot.roots.map {
                $0.url == directMediaURL.standardizedFileURL ? .file : .folder
            }
        )
        XCTAssertEqual(
            snapshot.items.map(\.url),
            [directMediaURL, folderMediaURL]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
        let directItem = try XCTUnwrap(
            snapshot.items.first {
                $0.url == directMediaURL.standardizedFileURL
            }
        )
        XCTAssertEqual(directItem.kind, .file)
        XCTAssertEqual(directItem.rootURL, directMediaURL.standardizedFileURL)
        XCTAssertEqual(directItem.relativePath, "")
        XCTAssertEqual(directItem.relativeDirectory, "")
        XCTAssertEqual(directItem.displayName, "Direct")
        XCTAssertEqual(directItem.fileSize, 3)
    }

    func testTypedFileSourceDoesNotExpandIntoReplacementDirectory()
        async throws {
        let rootURL = try makeSandbox()
        defer { removeSandbox(rootURL) }

        do {
            _ = try await FileSystemMediaLibraryScanner().scan(
                sources: [MediaSource(url: rootURL, kind: .file)]
            )
            XCTFail("Expected a source-kind mismatch")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(
                error,
                .sourceKindMismatch(rootURL, expected: .file)
            )
        }
    }

    func testTypedFolderSourceDoesNotChangeIntoReplacementFile()
        async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Replacement.mp4")
        try writeFile(at: fileURL, byteCount: 1)

        do {
            _ = try await FileSystemMediaLibraryScanner().scan(
                sources: [MediaSource(url: fileURL, kind: .folder)]
            )
            XCTFail("Expected a source-kind mismatch")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(
                error,
                .sourceKindMismatch(fileURL, expected: .folder)
            )
        }
    }

    func testFolderRepresentativeWinsWhenFileSourceIsAlreadyCovered() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let folderURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let mediaURL = folderURL.appendingPathComponent("Only.mp4")
        try writeFile(at: mediaURL, byteCount: 1)

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            sources: [
                MediaSource(url: mediaURL, kind: .file),
                MediaSource(url: folderURL, kind: .folder),
                MediaSource(url: mediaURL, kind: .file)
            ]
        )

        XCTAssertEqual(snapshot.roots.count, 1)
        XCTAssertEqual(snapshot.roots.first?.url, folderURL.standardizedFileURL)
        XCTAssertEqual(snapshot.roots.first?.kind, .folder)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.url, mediaURL.standardizedFileURL)
        XCTAssertEqual(snapshot.items.first?.kind, .folder)

        let directID = LibraryMediaItem.ID(mediaURL: mediaURL)
        XCTAssertEqual(snapshot.items.first?.id, directID)
        XCTAssertEqual(Set([snapshot.items[0].id, directID]).count, 1)
    }

    func testExcludesUnsupportedHiddenPackageAndSymbolicLinkEntries() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let nestedDirectoryURL = rootURL.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        let hiddenDirectoryURL = rootURL.appendingPathComponent(
            ".Hidden",
            isDirectory: true
        )
        let packageURL = rootURL.appendingPathComponent(
            "Archived.bundle",
            isDirectory: true
        )
        for directoryURL in [
            nestedDirectoryURL,
            hiddenDirectoryURL,
            packageURL
        ] {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        let includedURL = nestedDirectoryURL.appendingPathComponent("Included.mp4")
        let unsupportedURL = rootURL.appendingPathComponent("Unsupported.mkv")
        let hiddenFileURL = rootURL.appendingPathComponent(".Hidden.mov")
        let hiddenDescendantURL = hiddenDirectoryURL.appendingPathComponent("Hidden.m4v")
        let packageDescendantURL = packageURL.appendingPathComponent("Packaged.mp4")
        for fileURL in [
            includedURL,
            unsupportedURL,
            hiddenFileURL,
            hiddenDescendantURL,
            packageDescendantURL
        ] {
            try writeFile(at: fileURL, byteCount: 1)
        }

        let linkedFileURL = rootURL.appendingPathComponent("Linked.mp4")
        try FileManager.default.createSymbolicLink(
            at: linkedFileURL,
            withDestinationURL: includedURL
        )
        let linkedDirectoryURL = rootURL.appendingPathComponent(
            "Linked Directory",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectoryURL,
            withDestinationURL: nestedDirectoryURL
        )

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [rootURL]
        )

        XCTAssertEqual(snapshot.items.map(\.url), [includedURL.standardizedFileURL])
    }

    func testReportsInvalidAndInaccessibleRootsWithTypedErrors() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let missingRootURL = sandboxURL.appendingPathComponent(
            "Missing",
            isDirectory: true
        )
        do {
            _ = try await FileSystemMediaLibraryScanner().scan(
                rootURLs: [missingRootURL]
            )
            XCTFail("Expected a missing root to fail")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(
                error,
                .rootUnavailable(missingRootURL.standardizedFileURL)
            )
        }

        let unsupportedRootURL = sandboxURL.appendingPathComponent("Not Video.txt")
        try writeFile(at: unsupportedRootURL, byteCount: 1)
        do {
            _ = try await FileSystemMediaLibraryScanner().scan(
                rootURLs: [unsupportedRootURL]
            )
            XCTFail("Expected an unsupported file root to fail")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(
                error,
                .unsupportedMediaFile(unsupportedRootURL.standardizedFileURL)
            )
        }

        let validRootURL = sandboxURL.appendingPathComponent(
            "Valid",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: validRootURL,
            withIntermediateDirectories: true
        )
        let symbolicRootURL = sandboxURL.appendingPathComponent(
            "Linked Root",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicRootURL,
            withDestinationURL: validRootURL
        )
        do {
            _ = try await FileSystemMediaLibraryScanner().scan(
                rootURLs: [symbolicRootURL]
            )
            XCTFail("Expected a symbolic-link root to fail")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(
                error,
                .rootIsSymbolicLink(symbolicRootURL.standardizedFileURL)
            )
        }
    }

    func testUnavailableRootDoesNotHideOtherAccessibleRoots() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let validRootURL = sandboxURL.appendingPathComponent(
            "Valid",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: validRootURL,
            withIntermediateDirectories: true
        )
        let mediaURL = validRootURL.appendingPathComponent("Visible.mp4")
        try writeFile(at: mediaURL, byteCount: 1)
        let missingRootURL = sandboxURL.appendingPathComponent(
            "Offline",
            isDirectory: true
        )

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [missingRootURL, validRootURL]
        )

        XCTAssertEqual(snapshot.roots.map(\.url), [validRootURL.standardizedFileURL])
        XCTAssertEqual(snapshot.items.map(\.url), [mediaURL.standardizedFileURL])
    }

    func testUnreadableDescendantDoesNotDiscardOtherMediaInRoot() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let unreadableDirectoryURL = rootURL.appendingPathComponent(
            "Unreadable",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unreadableDirectoryURL,
            withIntermediateDirectories: true
        )

        let visibleMediaURL = rootURL.appendingPathComponent("Visible.mp4")
        let inaccessibleMediaURL = unreadableDirectoryURL
            .appendingPathComponent("Inaccessible.mov")
        try writeFile(at: visibleMediaURL, byteCount: 4)
        try writeFile(at: inaccessibleMediaURL, byteCount: 4)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadableDirectoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadableDirectoryURL.path
            )
        }

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [rootURL]
        )

        XCTAssertEqual(
            snapshot.items.map(\.url),
            [visibleMediaURL.standardizedFileURL]
        )
        XCTAssertEqual(
            snapshot.incompleteRootPaths,
            [rootURL.standardizedFileURL.path]
        )
    }

    func testAvailabilityRequiresReadableParentToConfirmMissingFile() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let existingItem = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent("Existing.mov"),
            displayName: "Existing",
            relativePath: "Existing.mov",
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
        try writeFile(at: existingItem.url, byteCount: 1)
        let missingItem = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL.appendingPathComponent("Missing.mov"),
            displayName: "Missing",
            relativePath: "Missing.mov",
            relativeDirectory: "",
            creationDate: nil,
            fileSize: 1
        )
        let unavailableItem = LibraryMediaItem(
            rootURL: rootURL,
            rootName: "Library",
            url: rootURL
                .appendingPathComponent("Offline", isDirectory: true)
                .appendingPathComponent("Unknown.mov"),
            displayName: "Unknown",
            relativePath: "Offline/Unknown.mov",
            relativeDirectory: "Offline",
            creationDate: nil,
            fileSize: 1
        )
        let scanner = FileSystemMediaLibraryScanner()
        let existingAvailability = await scanner.availability(
            of: existingItem
        )
        let missingAvailability = await scanner.availability(
            of: missingItem
        )
        let unavailableAvailability = await scanner.availability(
            of: unavailableItem
        )

        XCTAssertEqual(existingAvailability, .available)
        XCTAssertEqual(missingAvailability, .missing)
        XCTAssertEqual(unavailableAvailability, .temporarilyUnavailable)
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

    private func removeSandbox(_ sandboxURL: URL) {
        try? FileManager.default.removeItem(at: sandboxURL)
    }

    private func writeFile(at url: URL, byteCount: Int) throws {
        try Data(repeating: 0xA5, count: byteCount).write(to: url)
    }
}
