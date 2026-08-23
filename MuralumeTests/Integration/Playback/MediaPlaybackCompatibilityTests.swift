import Foundation
import XCTest
@testable import Muralume

@MainActor
final class MediaPlaybackCompatibilityTests: XCTestCase {
    private enum ThumbnailExpectation {
        static let pointSize = CGSize(width: 84, height: 48)
        static let scale: CGFloat = 2
    }

    func testLoadsF4VCompatibilityAliasWithoutChangingSource() async throws {
        let fixture = try TestMediaFixture.temporaryCopy(
            for: Self.self,
            fileExtension: "f4v"
        )
        defer { fixture.remove() }
        let originalData = try Data(contentsOf: fixture.url)
        let engine = AVFoundationPlaybackEngine()
        defer { engine.stop() }

        let duration = try await engine.load(
            ResolvedMediaSource(
                url: fixture.url,
                displayName: fixture.url.lastPathComponent
            )
        )

        XCTAssertEqual(duration, TestMediaFixture.duration, accuracy: 0.1)
        XCTAssertEqual(fixture.url.pathExtension, "f4v")
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalData)
    }

    func testCompatibilityLeaseCreatesAndRemovesCanonicalSymlink() throws {
        let fixture = try TestMediaFixture.temporaryCopy(
            for: Self.self,
            fileExtension: "f4v"
        )
        defer { fixture.remove() }
        let lease = try MediaPlaybackURLLease(sourceURL: fixture.url)
        let aliasURL = lease.url

        XCTAssertEqual(aliasURL.pathExtension, "mp4")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: aliasURL.path
            ),
            fixture.url.path
        )

        lease.invalidate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.url.path)
        )
    }

    func testThumbnailProviderGeneratesF4VCompatibilityThumbnail()
        async throws {
        let fixture = try TestMediaFixture.temporaryCopy(
            for: Self.self,
            fileExtension: "f4v"
        )
        defer { fixture.remove() }
        let item = try makeLibraryItem(for: fixture.url)
        let provider = QuickLookMediaThumbnailProvider()

        let image = await provider.thumbnail(
            for: item,
            size: ThumbnailExpectation.pointSize,
            scale: ThumbnailExpectation.scale
        )
        let thumbnail = try XCTUnwrap(image)

        XCTAssertGreaterThan(thumbnail.width, 0)
        XCTAssertGreaterThan(thumbnail.height, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.url.path)
        )
        await provider.shutdown()
    }

    private func makeLibraryItem(for url: URL) throws -> LibraryMediaItem {
        let values = try url.resourceValues(
            forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ]
        )
        let rootURL = url.deletingLastPathComponent()
        return LibraryMediaItem(
            rootURL: rootURL,
            rootName: rootURL.lastPathComponent,
            url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            relativePath: url.lastPathComponent,
            relativeDirectory: "",
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }
}
