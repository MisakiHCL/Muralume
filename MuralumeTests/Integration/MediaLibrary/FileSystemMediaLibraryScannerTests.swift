import Foundation
import XCTest
@testable import Muralume

@MainActor
final class FileSystemMediaLibraryScannerTests: XCTestCase {
    func testStopsImmediatelyWhenScanTimeBudgetIsExhausted() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let scanner = FileSystemMediaLibraryScanner(
            scanLimits: FileSystemMediaLibraryScanLimits(
                maximumDuration: .zero,
                maximumEstimatedWorkingSetBytes: 1_024
            )
        )

        do {
            _ = try await scanner.scan(rootURLs: [sandboxURL])
            XCTFail("Expected the scan time budget to stop the scan")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(error, .timeLimitExceeded)
        }
    }

    func testStopsBeforeRetainingMediaBeyondMemoryBudget() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        try writeFile(
            at: sandboxURL.appendingPathComponent("Large Library.mp4"),
            byteCount: 1
        )
        let scanner = FileSystemMediaLibraryScanner(
            scanLimits: FileSystemMediaLibraryScanLimits(
                maximumDuration: .seconds(60),
                maximumEstimatedWorkingSetBytes: 1
            )
        )

        do {
            _ = try await scanner.scan(rootURLs: [sandboxURL])
            XCTFail("Expected the scan memory budget to stop the scan")
        } catch let error as MediaLibraryScanError {
            XCTAssertEqual(error, .memoryLimitExceeded)
        }
    }

    func testScansEverySupportedVideoExtensionCaseInsensitively() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }

        let expectedExtensions: Set<String> = [
            "3g2",
            "3gp",
            "3gp2",
            "3gpp",
            "avi",
            "dif",
            "dv",
            "m1v",
            "m2t",
            "m2ts",
            "m2v",
            "m4v",
            "mov",
            "mp4",
            "mpe",
            "mpeg",
            "mpg",
            "mts",
            "qt",
            "sdv",
            "ts",
        ]
        XCTAssertEqual(
            MediaLibraryFilePolicy.supportedVideoExtensions,
            expectedExtensions
        )

        for fileExtension in expectedExtensions {
            let fileURL = sandboxURL.appendingPathComponent(
                "Video.\(fileExtension.uppercased())"
            )
            try writeFile(at: fileURL, byteCount: 1)
        }
        let unsupportedURL = sandboxURL.appendingPathComponent("Video.mkv")
        try writeFile(at: unsupportedURL, byteCount: 1)

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            rootURLs: [sandboxURL]
        )

        XCTAssertEqual(
            Set(snapshot.items.map { $0.url.pathExtension.lowercased() }),
            expectedExtensions
        )
        XCTAssertFalse(snapshot.items.contains { $0.url == unsupportedURL })
    }

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

    func testSourceIdentityInspectionRunsOncePerInputSource() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let sourceCount = 24
        let mediaURLs = try (0..<sourceCount).map { index in
            let url = sandboxURL.appendingPathComponent(
                "Video-\(index).mp4"
            )
            try writeFile(at: url, byteCount: index + 1)
            return url
        }
        let counter = FileSystemMediaSourceInspectionCounter()
        let scanner = FileSystemMediaLibraryScanner(
            sourceInspection: counter.makeInspection()
        )

        let snapshot = try await scanner.scan(
            sources: mediaURLs.reversed().map {
                MediaSource(url: $0, kind: .file)
            }
        )

        XCTAssertEqual(snapshot.roots.count, sourceCount)
        XCTAssertEqual(snapshot.items.count, sourceCount)
        XCTAssertEqual(counter.canonicalURLCount, sourceCount)
        XCTAssertEqual(counter.resourceIdentifierCount, sourceCount)
    }

    func testSingleSourceSkipsDeduplicationMetadataInspection() async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let mediaURL = sandboxURL.appendingPathComponent("Only.mp4")
        try writeFile(at: mediaURL, byteCount: 1)
        let counter = FileSystemMediaSourceInspectionCounter()
        let scanner = FileSystemMediaLibraryScanner(
            sourceInspection: counter.makeInspection()
        )

        let snapshot = try await scanner.scan(
            sources: [MediaSource(url: mediaURL, kind: .file)]
        )

        XCTAssertEqual(snapshot.items.map(\.url), [mediaURL])
        XCTAssertEqual(counter.canonicalURLCount, 0)
        XCTAssertEqual(counter.resourceIdentifierCount, 0)
    }

    func testManyUniqueFileSourcesUseNearLinearIdentityComparison() async {
        let sourceCount = 2_000
        let counter = SourceIdentifierEqualityCounter()
        let scanner = FileSystemMediaLibraryScanner(
            sourceInspection: FileSystemMediaSourceInspection(
                canonicalURL: { $0 },
                resourceIdentifier: { url in
                    CountingSourceIdentifier(
                        value: url.lastPathComponent,
                        counter: counter
                    )
                }
            )
        )
        let sources = (0..<sourceCount).map { index in
            MediaSource(
                url: URL(
                    fileURLWithPath: "/nonexistent/source-\(index).mp4"
                ),
                kind: .file
            )
        }

        do {
            _ = try await scanner.scan(sources: sources)
            XCTFail("Expected unavailable synthetic roots")
        } catch let error as MediaLibraryScanError {
            guard case .rootUnavailable = error else {
                return XCTFail("Unexpected scan error: \(error)")
            }
        } catch {
            XCTFail("Unexpected scan error: \(error)")
        }

        XCTAssertLessThan(counter.equalityCount, sourceCount * 2)
    }

    func testSourceNormalizationRespondsToCancellation() async {
        let sourceCount = 2_000
        let inspectionCount = LockedIntegerCounter()
        let scanner = FileSystemMediaLibraryScanner(
            sourceInspection: FileSystemMediaSourceInspection(
                canonicalURL: { url in
                    let count = inspectionCount.increment()
                    if count == 16 {
                        withUnsafeCurrentTask { task in
                            task?.cancel()
                        }
                    }
                    return url
                },
                resourceIdentifier: { _ in nil }
            )
        )
        let sources = (0..<sourceCount).map { index in
            MediaSource(
                url: URL(
                    fileURLWithPath: "/nonexistent/cancel-\(index).mp4"
                ),
                kind: .file
            )
        }
        let scanTask = Task {
            try await scanner.scan(sources: sources)
        }

        do {
            _ = try await scanTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: normalization checks cancellation between sources.
        } catch {
            XCTFail("Unexpected scan error: \(error)")
        }

        XCTAssertLessThan(inspectionCount.value, sourceCount)
    }

    func testFolderIdentityCoversMediaReachedThroughAnAliasAncestor()
        async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let folderURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let aliasContainerURL = sandboxURL.appendingPathComponent(
            "Alias",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: aliasContainerURL,
            withIntermediateDirectories: true
        )
        let libraryMediaURL = folderURL.appendingPathComponent("Inside.mp4")
        let aliasMediaURL = aliasContainerURL.appendingPathComponent(
            "Alias.mp4"
        )
        try writeFile(at: libraryMediaURL, byteCount: 1)
        try writeFile(at: aliasMediaURL, byteCount: 1)
        let folderIdentity = "folder-identity"
        let scanner = FileSystemMediaLibraryScanner(
            sourceInspection: FileSystemMediaSourceInspection(
                canonicalURL: { $0 },
                resourceIdentifier: { url in
                    switch url.standardizedFileURL.path {
                    case folderURL.standardizedFileURL.path,
                         aliasContainerURL.standardizedFileURL.path:
                        return NSString(string: folderIdentity)
                    default:
                        return NSString(string: url.path)
                    }
                }
            )
        )

        let snapshot = try await scanner.scan(
            sources: [
                MediaSource(url: aliasMediaURL, kind: .file),
                MediaSource(url: folderURL, kind: .folder)
            ]
        )

        XCTAssertEqual(snapshot.roots.map(\.url), [folderURL])
        XCTAssertEqual(snapshot.items.map(\.url), [libraryMediaURL])
    }

    func testCachedSourceIdentityPreservesHardLinkAndSymlinkDeduplication()
        async throws {
        let sandboxURL = try makeSandbox()
        defer { removeSandbox(sandboxURL) }
        let originalURL = sandboxURL.appendingPathComponent(
            "A-Original.mp4"
        )
        let hardLinkURL = sandboxURL.appendingPathComponent(
            "B-Hard-Link.mp4"
        )
        let symbolicLinkURL = sandboxURL.appendingPathComponent(
            "C-Symbolic-Link.mp4"
        )
        try writeFile(at: originalURL, byteCount: 1)
        try FileManager.default.linkItem(at: originalURL, to: hardLinkURL)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: originalURL
        )

        let snapshot = try await FileSystemMediaLibraryScanner().scan(
            sources: [symbolicLinkURL, hardLinkURL, originalURL].map {
                MediaSource(url: $0, kind: .file)
            }
        )

        XCTAssertEqual(
            snapshot.roots.map(\.url),
            [originalURL.standardizedFileURL]
        )
        XCTAssertEqual(
            snapshot.items.map(\.url),
            [originalURL.standardizedFileURL]
        )
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

private final class FileSystemMediaSourceInspectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCanonicalURLCount = 0
    private var storedResourceIdentifierCount = 0

    var canonicalURLCount: Int {
        lock.withLock { storedCanonicalURLCount }
    }

    var resourceIdentifierCount: Int {
        lock.withLock { storedResourceIdentifierCount }
    }

    func makeInspection() -> FileSystemMediaSourceInspection {
        let liveInspection = FileSystemMediaSourceInspection.live
        return FileSystemMediaSourceInspection(
            canonicalURL: { [self] url in
                lock.withLock {
                    storedCanonicalURLCount += 1
                }
                return liveInspection.canonicalURL(url)
            },
            resourceIdentifier: { [self] url in
                lock.withLock {
                    storedResourceIdentifierCount += 1
                }
                return liveInspection.resourceIdentifier(url)
            }
        )
    }
}

private final class LockedIntegerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storedValue += 1
            return storedValue
        }
    }
}

private final class SourceIdentifierEqualityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEqualityCount = 0

    var equalityCount: Int {
        lock.withLock { storedEqualityCount }
    }

    func recordComparison() {
        lock.withLock {
            storedEqualityCount += 1
        }
    }
}

private final class CountingSourceIdentifier: NSObject {
    private let value: String
    private let counter: SourceIdentifierEqualityCounter

    init(value: String, counter: SourceIdentifierEqualityCounter) {
        self.value = value
        self.counter = counter
    }

    override var hash: Int {
        value.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        counter.recordComparison()
        return (object as? CountingSourceIdentifier)?.value == value
    }
}
