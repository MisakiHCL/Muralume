import XCTest
@testable import Muralume

@MainActor
final class UserSelectedMediaSessionTests: XCTestCase {
    private enum TestStorage {
        static let suiteName = "com.muralume.tests.media-session"
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

    func testRejectsSameChildAndSymbolicAliasRoots() throws {
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
            fixture.defaults.array(
                forKey: "media-library.root-bookmarks"
            )?.count,
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
            forKey: "media-library.root-bookmarks"
        )

        let restoredURLs = fixture.session.restoreFolders()

        XCTAssertEqual(restoredURLs, [rootURL])
        XCTAssertEqual(
            fixture.recorder.startedURLs,
            [rootURL, childURL]
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs, [childURL])
        XCTAssertEqual(
            fixture.defaults.array(
                forKey: "media-library.root-bookmarks"
            )?.count,
            1
        )

        fixture.session.stop()
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [childURL, rootURL]
        )
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

        XCTAssertTrue(
            fixture.defaults.array(
                forKey: "media-library.root-bookmarks"
            )?.isEmpty == true
        )
        XCTAssertEqual(fixture.recorder.stoppedURLs, [rootURL])

        let remainingURLs = fixture.session.removeFolder(rootURL)

        XCTAssertTrue(remainingURLs.isEmpty)
        XCTAssertEqual(
            fixture.recorder.stoppedURLs,
            [rootURL, rootURL]
        )
    }

    private func makeSessionFixture() -> MediaSessionFixture {
        let suiteName = TestStorage.suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let recorder = SecurityScopeRecorder()
        let session = UserSelectedMediaSession(
            defaults: defaults,
            securityAccess: recorder.makeAccess()
        )
        return MediaSessionFixture(
            suiteName: suiteName,
            defaults: defaults,
            recorder: recorder,
            session: session
        )
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
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    func bookmark(for url: URL) -> Data {
        Data(url.absoluteString.utf8)
    }

    func makeAccess() -> SecurityScopedMediaAccess {
        SecurityScopedMediaAccess(
            makeBookmark: { [weak self] url in
                self?.bookmark(for: url)
            },
            resolveBookmark: { [weak self] bookmark in
                guard let url = self?.resolvedURLByBookmark[bookmark] else {
                    return nil
                }
                return SecurityScopedMediaAccess.ResolvedBookmark(
                    url: url,
                    isStale: false
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
