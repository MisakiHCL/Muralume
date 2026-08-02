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
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []
    private(set) var bookmarkedURLs: [URL] = []

    func bookmark(for url: URL) -> Data {
        Data(url.absoluteString.utf8)
    }

    func makeAccess() -> SecurityScopedMediaAccess {
        SecurityScopedMediaAccess(
            makeBookmark: { [weak self] url in
                self?.bookmarkedURLs.append(url)
                return self?.bookmark(for: url)
            },
            resolveBookmark: { [weak self] bookmark in
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
