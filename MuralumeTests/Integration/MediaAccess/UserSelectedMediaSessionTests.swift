import XCTest
@testable import Muralume

@MainActor
final class UserSelectedMediaSessionTests: XCTestCase {
    private enum TestStorage {
        static let suiteName = "com.muralume.tests.media-session"
        static let legacyBookmarkKey = "media-library.root-bookmarks"
        static let sourceRecordKey = "media-library.source-records"
        static let schemaVersion = 1

        enum RecordField {
            static let schemaVersion = "schemaVersion"
            static let kind = "kind"
            static let bookmark = "bookmark"
        }
    }

    private struct StoredSourceRecord: Hashable {
        let schemaVersion: Int
        let kind: MediaSourceKind
        let bookmark: Data

        init(
            schemaVersion: Int = TestStorage.schemaVersion,
            kind: MediaSourceKind,
            bookmark: Data
        ) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        init?(storedValue: Any) {
            guard let fields = storedValue as? [String: Any],
                  let schemaVersion = fields[
                      TestStorage.RecordField.schemaVersion
                  ] as? Int,
                  schemaVersion == TestStorage.schemaVersion,
                  let rawKind = fields[
                      TestStorage.RecordField.kind
                  ] as? String,
                  let kind = MediaSourceKind(rawValue: rawKind),
                  let bookmark = fields[
                      TestStorage.RecordField.bookmark
                  ] as? Data else {
                return nil
            }
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.bookmark = bookmark
        }

        var storedValue: [String: Any] {
            [
                TestStorage.RecordField.schemaVersion: schemaVersion,
                TestStorage.RecordField.kind: kind.rawValue,
                TestStorage.RecordField.bookmark: bookmark
            ]
        }
    }

    func testSelectedScopeIsReleasedAndResolvedScopeUsesExactURLUntilStop() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let selectedURL = URL(
            fileURLWithPath: "/tmp/Muralume Selected \(UUID().uuidString)",
            isDirectory: true
        )
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Muralume Scope/../Resolved \(UUID().uuidString)",
            isDirectory: true
        )
        fixture.recorder.resolvedURLByBookmark[
            fixture.recorder.bookmark(for: selectedURL)
        ] = resolvedURL

        let activeURLs = fixture.session.addFolders([selectedURL])

        XCTAssertEqual(activeURLs, [resolvedURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [resolvedURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [selectedURL])

        fixture.session.stop()

        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [selectedURL, resolvedURL]
        )
        XCTAssertNotEqual(resolvedURL, resolvedURL.standardizedFileURL)
    }

    func testSingleFileUsesAnExactBookmarkAndReturnsPlaybackIntent() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Selected.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL

        let update = fixture.session.addSources([fileURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertEqual(update.requestedFileURLs, [fileURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertTrue(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [fileURL])
        XCTAssertNotEqual(
            fixture.recorder.bookmarkedURLs.first,
            fileURL.deletingLastPathComponent()
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])

        fixture.session.stop()
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL, fileURL])
    }

    func testTypedFileRecordRestoresAsFileAcrossSessions() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Persisted.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL

        _ = fixture.session.addSources([fileURL])
        fixture.session.stop()

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        XCTAssertEqual(
            restoredSession.restoreSources(),
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertFalse(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .file, bookmark: bookmark)]
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )

        restoredSession.stop()
    }

    func testFolderCoversFileRequestWithoutAddingADuplicateGrant() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Covered.mov")
        try Data([0xA5]).write(to: fileURL)
        for url in [sandboxURL, fileURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([sandboxURL])

        let update = fixture.session.addSources([fileURL, fileURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: sandboxURL, kind: .folder)]
        )
        XCTAssertEqual(update.requestedFileURLs, [fileURL])
        XCTAssertEqual(update.acceptedRequestCount, 2)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [sandboxURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [sandboxURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: fixture.recorder.bookmark(for: sandboxURL)
                )
            ]
        )

        fixture.session.stop()
    }

    func testSameBatchParentFolderAndExplicitFileKeepsPlaybackIntentForEitherOrder()
        throws {
        for selectsFileFirst in [false, true] {
            let fixture = makeSessionFixture()
            defer { fixture.clearDefaults() }
            let sandboxURL = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandboxURL) }
            let parentURL = sandboxURL.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let nestedURL = parentURL.appendingPathComponent(
                "Nested",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            let canonicalFileURL = parentURL.appendingPathComponent(
                "Selected.mp4"
            )
            try Data([0xA5]).write(to: canonicalFileURL)
            let selectedFileURL = nestedURL.appendingPathComponent(
                "../Selected.mp4"
            )
            let parentBookmark = fixture.recorder.bookmark(for: parentURL)
            let fileBookmark = fixture.recorder.bookmark(for: selectedFileURL)
            fixture.recorder.resolvedURLByBookmark[parentBookmark] = parentURL
            fixture.recorder.resolvedURLByBookmark[fileBookmark] =
                canonicalFileURL
            let selectedURLs = selectsFileFirst
                ? [selectedFileURL, parentURL]
                : [parentURL, selectedFileURL]

            let update = fixture.session.addSources(selectedURLs)

            XCTAssertEqual(
                update.activeSources,
                [MediaSource(url: parentURL, kind: .folder)]
            )
            XCTAssertEqual(update.requestedFileURLs, [canonicalFileURL])
            XCTAssertEqual(update.acceptedRequestCount, 2)
            XCTAssertEqual(update.rejectedRequestCount, 0)
            XCTAssertTrue(update.didChangeSources)
            XCTAssertEqual(
                storedSourceRecords(in: fixture.defaults),
                [
                    StoredSourceRecord(
                        kind: .folder,
                        bookmark: parentBookmark
                    )
                ]
            )
            XCTAssertEqual(
                fixture.recorder.bookmarkedURLs,
                selectsFileFirst
                    ? [selectedFileURL, parentURL]
                    : [parentURL]
            )
            XCTAssertEqual(
                fixture.recorder.startedURLs,
                selectsFileFirst
                    ? [canonicalFileURL, parentURL]
                    : [parentURL]
            )
            if selectsFileFirst {
                XCTAssertTrue(
                    fixture.recorder.stoppedURLs.contains(canonicalFileURL)
                )
            }

            fixture.session.stop()
            let stopCount = fixture.recorder.stoppedURLs.count
            XCTAssertEqual(fixture.recorder.stoppedURLs.last, parentURL)

            fixture.session.stop()
            XCTAssertEqual(fixture.recorder.stoppedURLs.count, stopCount)
        }
    }

    func testCoveredSymbolicLinkReturnsCanonicalFilePlaybackIntent() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let rootURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let targetURL = rootURL.appendingPathComponent("Target.mp4")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Linked.mp4")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let rootBookmark = fixture.recorder.bookmark(for: rootURL)
        fixture.recorder.resolvedURLByBookmark[rootBookmark] = rootURL
        _ = fixture.session.addSources([rootURL])

        let update = fixture.session.addSources([linkURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: rootURL, kind: .folder)]
        )
        XCTAssertEqual(update.requestedFileURLs, [targetURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [rootURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [rootURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [rootURL, linkURL])

        fixture.session.stop()
    }

    func testHardLinkDuplicateUsesPersistedFilePlaybackURL() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let persistedURL = sandboxURL.appendingPathComponent("Persisted.mp4")
        let duplicateURL = sandboxURL.appendingPathComponent("Duplicate.mp4")
        try Data([0xA5]).write(to: persistedURL)
        try FileManager.default.linkItem(
            at: persistedURL,
            to: duplicateURL
        )
        let bookmark = fixture.recorder.bookmark(for: persistedURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = persistedURL
        _ = fixture.session.addSources([persistedURL])

        let update = fixture.session.addSources([duplicateURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: persistedURL, kind: .file)]
        )
        XCTAssertEqual(update.requestedFileURLs, [persistedURL])
        XCTAssertEqual(update.acceptedRequestCount, 1)
        XCTAssertEqual(update.rejectedRequestCount, 0)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [persistedURL])

        fixture.session.stop()
    }

    func testUniqueSymbolicLinkIsRejectedWithoutPersistingOrStartingScope() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let targetURL = sandboxURL.appendingPathComponent("Target.mov")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Unique.mov")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let update = fixture.session.addSources([linkURL])

        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(fixture.recorder.bookmarkedURLs.isEmpty)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [linkURL])
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )
    }

    func testAddingParentFolderReplacesFileGrantAfterFolderPersists() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("First.m4v")
        try Data([0xA5]).write(to: fileURL)
        for url in [fileURL, sandboxURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([fileURL])

        let update = fixture.session.addSources([sandboxURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: sandboxURL, kind: .folder)]
        )
        XCTAssertTrue(update.didChangeSources)
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL, sandboxURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .folder,
                    bookmark: fixture.recorder.bookmark(for: sandboxURL)
                )
            ]
        )
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [fileURL, fileURL, sandboxURL]
        )

        fixture.session.stop()
    }

    func testParentFolderIsRejectedWhenChildFolderIsAlreadyActive() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        for url in [childURL, parentURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([childURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([parentURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: childURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [childURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [childURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, parentURL]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRequest
        )

        fixture.session.stop()
    }

    func testChildFolderIsRejectedWhenParentFolderIsAlreadyActive() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        for url in [parentURL, childURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([parentURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([childURL])

        XCTAssertEqual(
            update.activeSources,
            [MediaSource(url: parentURL, kind: .folder)]
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [parentURL])
        XCTAssertEqual(fixture.recorder.startedURLs, [parentURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [parentURL, childURL]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRequest
        )

        fixture.session.stop()
    }

    func testParentFolderConflictPreservesCoveredFileAndChildFolder() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let parentURL = sandboxURL.appendingPathComponent(
            "Library",
            isDirectory: true
        )
        let childURL = parentURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        let fileURL = parentURL.appendingPathComponent("Loose.mp4")
        try Data([0xA5]).write(to: fileURL)
        for url in [fileURL, childURL, parentURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }
        _ = fixture.session.addSources([fileURL, childURL])
        let recordsBeforeRequest = storedSourceRecords(in: fixture.defaults)

        let update = fixture.session.addSources([parentURL])

        XCTAssertEqual(
            Set(update.activeSources),
            Set([
                MediaSource(url: fileURL, kind: .file),
                MediaSource(url: childURL, kind: .folder)
            ])
        )
        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertFalse(update.didChangeSources)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(
            fixture.recorder.bookmarkedURLs,
            [fileURL, childURL]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL, childURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [fileURL, childURL, parentURL]
        )
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(recordsBeforeRequest)
        )

        fixture.session.stop()
    }

    func testDeduplicatesSameChildAndSymbolicAliasRoots() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent(
            "Root",
            isDirectory: true
        )
        let childURL = rootURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        let symbolicAliasURL = sandboxURL.appendingPathComponent(
            "Root Alias",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicAliasURL,
            withDestinationURL: rootURL
        )
        defer {
            try? FileManager.default.removeItem(at: sandboxURL)
        }

        for url in [rootURL, childURL, symbolicAliasURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        XCTAssertEqual(fixture.session.addFolders([rootURL]), [rootURL])
        XCTAssertEqual(fixture.session.addFolders([rootURL]).count, 1)
        XCTAssertEqual(fixture.session.addFolders([childURL]).count, 1)
        XCTAssertEqual(
            fixture.session.addFolders([symbolicAliasURL]).count,
            1
        )

        XCTAssertEqual(fixture.recorder.startedURLs, [rootURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults).count,
            1
        )

        fixture.session.stop()
    }

    func testRestoreDropsLegacyOverlappingBookmarksAndStopsRejectedURLs() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent(
            "Root",
            isDirectory: true
        )
        let childURL = rootURL.appendingPathComponent(
            "Child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: sandboxURL)
        }

        let rootBookmark = fixture.recorder.bookmark(for: rootURL)
        let childBookmark = fixture.recorder.bookmark(for: childURL)
        fixture.recorder.resolvedURLByBookmark[rootBookmark] = rootURL
        fixture.recorder.resolvedURLByBookmark[childBookmark] = childURL
        fixture.defaults.set(
            [rootBookmark, childBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredURLs = fixture.session.restoreFolders()

        XCTAssertEqual(restoredURLs, [rootURL])
        XCTAssertEqual(
            fixture.recorder.startedURLs,
            [rootURL, childURL]
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs, [childURL])
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: rootBookmark)]
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )

        fixture.session.stop()
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, rootURL]
        )
    }

    func testLegacyFolderBookmarkMigratesToTypedFolderRecord() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let folderURL = sandboxURL.appendingPathComponent(
            "Folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let bookmark = fixture.recorder.bookmark(for: folderURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = folderURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredSources = fixture.session.restoreSources()

        XCTAssertEqual(
            restoredSources,
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertFalse(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [StoredSourceRecord(kind: .folder, bookmark: bookmark)]
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )

        fixture.session.stop()
    }

    func testLegacyFileBookmarkIsNotUpgradedToTypedFileRecord() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Legacy.mp4")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
    }

    func testTypedFileRecordRejectsDirectoryAtSameURL() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let sourceURL = sandboxURL.appendingPathComponent("Changed.mp4")
        try Data([0xA5]).write(to: sourceURL)
        let bookmark = fixture.recorder.bookmark(for: sourceURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = sourceURL
        _ = fixture.session.addSources([sourceURL])
        fixture.session.stop()
        let recordsBeforeRestore = storedSourceRecords(in: fixture.defaults)
        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )

        XCTAssertTrue(restoredSession.restoreSources().isEmpty)
        XCTAssertTrue(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRestore
        )
        XCTAssertEqual(fixture.recorder.startedURLs.last, sourceURL)
        XCTAssertEqual(fixture.recorder.stoppedURLs.last, sourceURL)
        restoredSession.stop()
    }

    func testTypedFolderRecordRejectsFileAtSameURL() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let sourceURL = sandboxURL.appendingPathComponent("Changed")
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        let bookmark = fixture.recorder.bookmark(for: sourceURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = sourceURL
        _ = fixture.session.addSources([sourceURL])
        fixture.session.stop()
        let recordsBeforeRestore = storedSourceRecords(in: fixture.defaults)
        try FileManager.default.removeItem(at: sourceURL)
        try Data([0xA5]).write(to: sourceURL)

        let restoredSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: Self.liveSourceKind(at:)
        )

        XCTAssertTrue(restoredSession.restoreSources().isEmpty)
        XCTAssertTrue(restoredSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            recordsBeforeRestore
        )
        XCTAssertEqual(fixture.recorder.startedURLs.last, sourceURL)
        XCTAssertEqual(fixture.recorder.stoppedURLs.last, sourceURL)
        restoredSession.stop()
    }

    func testTypedFileRecordWithUnsupportedExtensionRemainsUnavailable() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Unsupported.txt")
        try Data([0xA5]).write(to: fileURL)
        let bookmark = fixture.recorder.bookmark(for: fileURL)
        let record = StoredSourceRecord(kind: .file, bookmark: bookmark)
        fixture.recorder.resolvedURLByBookmark[bookmark] = fileURL
        fixture.defaults.set(
            [record.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [record]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [fileURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
    }

    func testStaleTypedBookmarkRefreshPreservesFileKind() throws {
        let fixture = makeSessionFixture(
            sourceKindResolver: Self.liveSourceKind(at:)
        )
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let fileURL = sandboxURL.appendingPathComponent("Stale.mp4")
        try Data([0xA5]).write(to: fileURL)
        let staleBookmark = Data("stale-bookmark".utf8)
        let refreshedBookmark = fixture.recorder.bookmark(for: fileURL)
        fixture.recorder.resolvedURLByBookmark[staleBookmark] = fileURL
        fixture.recorder.staleBookmarks.insert(staleBookmark)
        fixture.defaults.set(
            [
                StoredSourceRecord(
                    kind: .file,
                    bookmark: staleBookmark
                ).storedValue
            ],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: fileURL, kind: .file)]
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [
                StoredSourceRecord(
                    kind: .file,
                    bookmark: refreshedBookmark
                )
            ]
        )
        XCTAssertEqual(fixture.recorder.bookmarkedURLs, [fileURL])
        fixture.session.stop()
    }

    func testUnknownAndDamagedTypedRecordsRemainStored() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let unknownRecord: [String: Any] = [
            TestStorage.RecordField.schemaVersion: 99,
            TestStorage.RecordField.kind: MediaSourceKind.file.rawValue,
            TestStorage.RecordField.bookmark: Data([0xA5])
        ]
        let damagedRecord = "damaged-record"
        fixture.defaults.set(
            [unknownRecord, damagedRecord],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        let storedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(storedValues.count, 2)
        XCTAssertEqual(
            (storedValues[0] as? [String: Any])?[
                TestStorage.RecordField.schemaVersion
            ] as? Int,
            99
        )
        XCTAssertEqual(storedValues[1] as? String, damagedRecord)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertTrue(fixture.recorder.stoppedURLs.isEmpty)
    }

    func testFolderRemovalPersistsBeforeReleasingActiveScope() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }

        let rootURL = URL(
            fileURLWithPath: "/tmp/Muralume Removal \(UUID().uuidString)",
            isDirectory: true
        )
        let bookmark = fixture.recorder.bookmark(for: rootURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = rootURL
        XCTAssertEqual(fixture.session.addFolders([rootURL]), [rootURL])

        fixture.session.prepareToRemoveFolder(rootURL)

        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [rootURL])

        let remainingURLs = fixture.session.removeFolder(rootURL)

        XCTAssertTrue(remainingURLs.isEmpty)
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [rootURL, rootURL]
        )
    }

    func testRestorePreservesBookmarkWhenSourceKindIsUnavailable() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in nil })
        defer { fixture.clearDefaults() }
        let unavailableURL = URL(fileURLWithPath: "/Volumes/Offline/Video.mp4")
        let bookmark = fixture.recorder.bookmark(for: unavailableURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = unavailableURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [unavailableURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [unavailableURL])
    }

    func testRestorePreservesUniqueSymbolicLinkWithoutActivatingIt() throws {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let sandboxURL = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandboxURL) }
        let targetURL = sandboxURL.appendingPathComponent("Target.m4v")
        try Data([0xA5]).write(to: targetURL)
        let linkURL = sandboxURL.appendingPathComponent("Legacy.m4v")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let bookmark = fixture.recorder.bookmark(for: linkURL)
        fixture.recorder.resolvedURLByBookmark[bookmark] = linkURL
        fixture.defaults.set(
            [bookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        let restoredSources = fixture.session.restoreSources()

        XCTAssertTrue(restoredSources.isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: TestStorage.legacyBookmarkKey
            ) as? [Data],
            [bookmark]
        )
        XCTAssertEqual(fixture.recorder.startedURLs, [linkURL])
        XCTAssertEqual(fixture.recorder.stoppedURLs, [linkURL])
    }

    func testImportLimitRejectsOverflowAndReleasesEverySelectedScope() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let requestedURLs = (0...MediaImportPolicy.maximumTopLevelSourceCount)
            .map {
                URL(fileURLWithPath: "/tmp/Muralume Import \($0).mp4")
            }
        for url in requestedURLs {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        let update = fixture.session.addSources(requestedURLs)

        XCTAssertEqual(
            update.acceptedRequestCount,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertEqual(
            update.activeSources.count,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.startedURLs.count,
            MediaImportPolicy.maximumTopLevelSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.stoppedURLs.count,
            requestedURLs.count
        )

        fixture.session.stop()
    }

    func testActiveSourceLimitAppliesAcrossSeparateImports() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let initialURLs = (0..<MediaImportPolicy.maximumActiveSourceCount)
            .map {
                URL(fileURLWithPath: "/tmp/Muralume Active \($0).mp4")
            }
        let overflowURL = URL(
            fileURLWithPath: "/tmp/Muralume Active Overflow.mp4"
        )
        for url in initialURLs + [overflowURL] {
            fixture.recorder.resolvedURLByBookmark[
                fixture.recorder.bookmark(for: url)
            ] = url
        }

        let initialUpdate = fixture.session.addSources(initialURLs)
        let bookmarkCountBeforeOverflow = fixture.recorder.bookmarkedURLs.count
        let overflowUpdate = fixture.session.addSources([overflowURL])

        XCTAssertEqual(
            initialUpdate.acceptedRequestCount,
            MediaImportPolicy.maximumActiveSourceCount
        )
        XCTAssertEqual(overflowUpdate.acceptedRequestCount, 0)
        XCTAssertEqual(overflowUpdate.rejectedRequestCount, 1)
        XCTAssertFalse(overflowUpdate.didChangeSources)
        XCTAssertEqual(
            overflowUpdate.activeSources.count,
            MediaImportPolicy.maximumActiveSourceCount
        )
        XCTAssertEqual(
            fixture.recorder.bookmarkedURLs.count,
            bookmarkCountBeforeOverflow
        )
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults).count,
            MediaImportPolicy.maximumActiveSourceCount
        )

        fixture.session.stop()
    }

    func testRestoreDefersOverflowRecordsWithoutDiscardingThem() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let recordCount =
            MediaImportPolicy.maximumRestoredSourceRecordCount + 1
        let records = (0..<recordCount).map { index in
            let name = String(format: "%03d", index)
            let url = URL(
                fileURLWithPath: "/tmp/Muralume Restored \(name).mp4"
            )
            let bookmark = fixture.recorder.bookmark(for: url)
            fixture.recorder.resolvedURLByBookmark[bookmark] = url
            return StoredSourceRecord(kind: .file, bookmark: bookmark)
        }
        fixture.defaults.set(
            records.map(\.storedValue),
            forKey: TestStorage.sourceRecordKey
        )

        let firstRestore = fixture.session.restoreSources()

        XCTAssertEqual(
            firstRestore.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(records)
        )
        XCTAssertEqual(
            fixture.recorder.startedURLs.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: { _ in .file }
        )
        let secondRestore = secondSession.restoreSources()

        XCTAssertEqual(Set(secondRestore), Set(firstRestore))
        XCTAssertTrue(secondSession.hasUnavailablePersistedSources)
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(records)
        )

        secondSession.stop()
    }

    func testDeferredTypedRecordAdvancesPastMixedUnavailablePrefix() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let firstURL = URL(
            fileURLWithPath: "/tmp/Muralume Restored First.mp4"
        )
        let deferredURL = URL(
            fileURLWithPath: "/tmp/Muralume Restored Deferred.mp4"
        )
        let firstRecord = StoredSourceRecord(
            kind: .file,
            bookmark: fixture.recorder.bookmark(for: firstURL)
        )
        let deferredRecord = StoredSourceRecord(
            kind: .file,
            bookmark: fixture.recorder.bookmark(for: deferredURL)
        )
        fixture.recorder.resolvedURLByBookmark[firstRecord.bookmark] = firstURL
        fixture.recorder.resolvedURLByBookmark[deferredRecord.bookmark] =
            deferredURL
        let damagedValues: [Any] = (
            0..<(MediaImportPolicy.maximumRestoredSourceRecordCount - 1)
        ).map { "damaged-record-\($0)" }
        var storedValues: [Any] = [firstRecord.storedValue]
        storedValues.append(contentsOf: damagedValues)
        storedValues.append(deferredRecord.storedValue)
        fixture.defaults.set(
            storedValues,
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: firstURL, kind: .file)]
        )
        let reorderedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(reorderedValues.count, storedValues.count)
        XCTAssertEqual(
            StoredSourceRecord(storedValue: reorderedValues[0]),
            firstRecord
        )
        XCTAssertEqual(
            StoredSourceRecord(storedValue: reorderedValues[1]),
            deferredRecord
        )

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder,
            sourceKindResolver: { _ in .file }
        )
        XCTAssertEqual(
            Set(secondSession.restoreSources()),
            Set([
                MediaSource(url: firstURL, kind: .file),
                MediaSource(url: deferredURL, kind: .file)
            ])
        )
        let persistedValues = fixture.defaults.array(
            forKey: TestStorage.sourceRecordKey
        ) ?? []
        XCTAssertEqual(persistedValues.count, storedValues.count)
        XCTAssertEqual(
            Set(persistedValues.compactMap { $0 as? String }),
            Set(damagedValues.compactMap { $0 as? String })
        )

        secondSession.stop()
    }

    func testDeferredLegacyBookmarkAdvancesPastUnavailablePrefix() {
        let fixture = makeSessionFixture()
        defer { fixture.clearDefaults() }
        let unavailableBookmarks = (
            0..<MediaImportPolicy.maximumRestoredSourceRecordCount
        ).map { Data("unavailable-bookmark-\($0)".utf8) }
        let folderURL = URL(
            fileURLWithPath: "/tmp/Muralume Legacy Deferred",
            isDirectory: true
        )
        let deferredBookmark = fixture.recorder.bookmark(for: folderURL)
        fixture.recorder.resolvedURLByBookmark[deferredBookmark] = folderURL
        fixture.defaults.set(
            unavailableBookmarks + [deferredBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        let reorderedBookmarks = fixture.defaults.array(
            forKey: TestStorage.legacyBookmarkKey
        ) as? [Data]
        XCTAssertEqual(reorderedBookmarks?.count, unavailableBookmarks.count + 1)
        XCTAssertEqual(reorderedBookmarks?.first, deferredBookmark)

        fixture.session.stop()
        let secondSession = makeSession(
            defaults: fixture.defaults,
            recorder: fixture.recorder
        )
        XCTAssertEqual(
            secondSession.restoreSources(),
            [MediaSource(url: folderURL, kind: .folder)]
        )
        XCTAssertEqual(
            Set(
                fixture.defaults.array(
                    forKey: TestStorage.legacyBookmarkKey
                ) as? [Data] ?? []
            ),
            Set(unavailableBookmarks)
        )

        secondSession.stop()
    }

    func testLegacyRestoreProgressesPastOfflineTypedBudgetPrefix() {
        let fixture = makeSessionFixture(sourceKindResolver: { url in
            url.hasDirectoryPath ? .folder : .file
        })
        defer { fixture.clearDefaults() }
        let typedRecords = (
            0..<MediaImportPolicy.maximumRestoredSourceRecordCount
        ).map { index in
            StoredSourceRecord(
                kind: .file,
                bookmark: Data("offline-typed-bookmark-\(index)".utf8)
            )
        }
        let legacyFolderURL = URL(
            fileURLWithPath: "/tmp/Muralume Legacy Budget Progress",
            isDirectory: true
        )
        let legacyBookmark = fixture.recorder.bookmark(for: legacyFolderURL)
        fixture.recorder.resolvedURLByBookmark[legacyBookmark] = legacyFolderURL
        fixture.defaults.set(
            typedRecords.map(\.storedValue),
            forKey: TestStorage.sourceRecordKey
        )
        fixture.defaults.set(
            [legacyBookmark],
            forKey: TestStorage.legacyBookmarkKey
        )

        XCTAssertEqual(
            fixture.session.restoreSources(),
            [MediaSource(url: legacyFolderURL, kind: .folder)]
        )
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertEqual(
            fixture.recorder.resolvedBookmarks.count,
            MediaImportPolicy.maximumRestoredSourceRecordCount
        )
        XCTAssertNil(
            fixture.defaults.array(forKey: TestStorage.legacyBookmarkKey)
        )
        XCTAssertEqual(
            Set(storedSourceRecords(in: fixture.defaults)),
            Set(
                typedRecords + [
                    StoredSourceRecord(
                        kind: .folder,
                        bookmark: legacyBookmark
                    )
                ]
            )
        )

        fixture.session.stop()
    }

    func testOversizedPersistedBookmarkIsPreservedWithoutResolution() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let fileURL = URL(
            fileURLWithPath: "/tmp/Muralume Oversized Persisted.mp4"
        )
        let oversizedBookmark = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )
        let record = StoredSourceRecord(
            kind: .file,
            bookmark: oversizedBookmark
        )
        fixture.recorder.resolvedURLByBookmark[oversizedBookmark] = fileURL
        fixture.defaults.set(
            [record.storedValue],
            forKey: TestStorage.sourceRecordKey
        )

        XCTAssertTrue(fixture.session.restoreSources().isEmpty)
        XCTAssertTrue(fixture.session.hasUnavailablePersistedSources)
        XCTAssertTrue(fixture.recorder.resolvedBookmarks.isEmpty)
        XCTAssertEqual(
            storedSourceRecords(in: fixture.defaults),
            [record]
        )
    }

    func testOversizedGeneratedBookmarkIsRejectedBeforeResolution() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let fileURL = URL(
            fileURLWithPath: "/tmp/Muralume Oversized Generated.mp4"
        )
        fixture.recorder.generatedBookmarkByURL[fileURL] = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )

        let update = fixture.session.addSources([fileURL])

        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(fixture.recorder.resolvedBookmarks.isEmpty)
        XCTAssertTrue(fixture.recorder.startedURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.stoppedURLs, [fileURL])
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
    }

    func testOversizedStaleBookmarkRefreshIsRejectedBeforeAcceptance() {
        let fixture = makeSessionFixture(sourceKindResolver: { _ in .file })
        defer { fixture.clearDefaults() }
        let selectedURL = URL(
            fileURLWithPath: "/tmp/Muralume Stale Selected.mp4"
        )
        let resolvedURL = URL(
            fileURLWithPath: "/tmp/Muralume Stale Resolved.mp4"
        )
        let initialBookmark = fixture.recorder.bookmark(for: selectedURL)
        fixture.recorder.resolvedURLByBookmark[initialBookmark] = resolvedURL
        fixture.recorder.staleBookmarks.insert(initialBookmark)
        fixture.recorder.generatedBookmarkByURL[resolvedURL] = Data(
            repeating: 0xA5,
            count: MediaImportPolicy.maximumBookmarkByteCount + 1
        )

        let update = fixture.session.addSources([selectedURL])

        XCTAssertEqual(update.acceptedRequestCount, 0)
        XCTAssertEqual(update.rejectedRequestCount, 1)
        XCTAssertTrue(update.activeSources.isEmpty)
        XCTAssertTrue(update.requestedFileURLs.isEmpty)
        XCTAssertEqual(fixture.recorder.startedURLs, [resolvedURL])
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [resolvedURL, selectedURL]
        )
        XCTAssertTrue(storedSourceRecords(in: fixture.defaults).isEmpty)
    }

    private func makeSessionFixture(
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            $0.hasDirectoryPath ? .folder : .file
        }
    ) -> MediaSessionFixture {
        let suiteName = TestStorage.suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let recorder = SecurityScopeRecorder()
        let session = UserSelectedMediaSession(
            defaults: defaults,
            securityAccess: recorder.makeAccess(),
            sourceKindResolver: sourceKindResolver
        )
        return MediaSessionFixture(
            suiteName: suiteName,
            defaults: defaults,
            recorder: recorder,
            session: session
        )
    }

    private func makeSession(
        defaults: UserDefaults,
        recorder: SecurityScopeRecorder,
        sourceKindResolver: @escaping (URL) -> MediaSourceKind? = {
            $0.hasDirectoryPath ? .folder : .file
        }
    ) -> UserSelectedMediaSession {
        UserSelectedMediaSession(
            defaults: defaults,
            securityAccess: recorder.makeAccess(),
            sourceKindResolver: sourceKindResolver
        )
    }

    private func storedSourceRecords(
        in defaults: UserDefaults
    ) -> [StoredSourceRecord] {
        (defaults.array(forKey: TestStorage.sourceRecordKey) ?? [])
            .compactMap(StoredSourceRecord.init(storedValue:))
    }

    nonisolated private static func liveSourceKind(
        at url: URL
    ) -> MediaSourceKind? {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else {
            return nil
        }
        if values.isDirectory == true {
            return .folder
        }
        if values.isRegularFile == true {
            return .file
        }
        return nil
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
}

@MainActor
private struct MediaSessionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let recorder: SecurityScopeRecorder
    let session: UserSelectedMediaSession

    func clearDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class SecurityScopeRecorder {
    var resolvedURLByBookmark: [Data: URL] = [:]
    var staleBookmarks: Set<Data> = []
    var generatedBookmarkByURL: [URL: Data] = [:]
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []
    private(set) var bookmarkedURLs: [URL] = []
    private(set) var resolvedBookmarks: [Data] = []

    func bookmark(for url: URL) -> Data {
        generatedBookmarkByURL[url] ?? Data(url.absoluteString.utf8)
    }

    func makeAccess() -> SecurityScopedMediaAccess {
        SecurityScopedMediaAccess(
            makeBookmark: { [weak self] url in
                self?.bookmarkedURLs.append(url)
                return self?.bookmark(for: url)
            },
            resolveBookmark: { [weak self] bookmark in
                self?.resolvedBookmarks.append(bookmark)
                guard let url = self?.resolvedURLByBookmark[bookmark] else {
                    return nil
                }
                return SecurityScopedMediaAccess.ResolvedBookmark(
                    url: url,
                    isStale: self?.staleBookmarks.contains(bookmark) == true
                )
            },
            startAccess: { [weak self] url in
                self?.startedURLs.append(url)
                return true
            },
            stopAccess: { [weak self] url in
                self?.stoppedURLs.append(url)
            }
        )
    }
}
