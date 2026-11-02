import CoreGraphics
import Foundation
import QuickLookThumbnailing
import XCTest
@testable import Muralume

@MainActor
final class MediaThumbnailCacheTests: XCTestCase {
    func testWarmThumbnailRemainsAvailableDuringLayoutAndScaleChangesWithoutSkippingExactGeneration() async throws {
        let image = try makeImage()
        let generator = PreviewThumbnailGenerator(image: image)
        let provider = QuickLookMediaThumbnailProvider(generator: generator, cacheMissDelay: .zero)
        let item = makeItem()
        let listSize = CGSize(width: 84, height: 48)
        _ = await provider.thumbnail(for: item, size: listSize, scale: 2)

        for size in [CGSize(width: 4, height: 4), CGSize(width: 104, height: 104), CGSize(width: 108, height: 108)] {
            XCTAssertNil(provider.cachedThumbnail(for: item, size: size, scale: 2))
            XCTAssertTrue(provider.cachedPreviewThumbnail(for: item) === image)
        }
        XCTAssertNil(provider.cachedThumbnail(for: item, size: listSize, scale: 3))
        XCTAssertTrue(provider.cachedPreviewThumbnail(for: item) === image)
        XCTAssertEqual(generator.generationCount, 1, "Synchronous first-frame previews must not start media work")

        _ = await provider.thumbnail(for: item, size: CGSize(width: 104, height: 104), scale: 2)
        XCTAssertEqual(generator.generationCount, 2, "A preview must not suppress the requested resolution")
        await provider.shutdown()
    }

    func testSameFilePreviewCrossesRootRepresentationsButRespectsRequestedRootInvalidation() async throws {
        let image = try makeImage()
        let provider = QuickLookMediaThumbnailProvider(
            generator: PreviewThumbnailGenerator(image: image), cacheMissDelay: .zero
        )
        let libraryItem = makeItem()
        let playlistItem = makeItem(asFileRoot: true)
        XCTAssertNotEqual(libraryItem.id.rootPath, playlistItem.id.rootPath)
        XCTAssertEqual(libraryItem.id, playlistItem.id)
        XCTAssertEqual(libraryItem.id.standardizedMediaPath, playlistItem.id.standardizedMediaPath)
        let playlistRoot = MediaLibraryRoot.ID(standardizedPath: playlistItem.id.rootPath)
        await provider.invalidateThumbnails(forRootID: playlistRoot)
        _ = await provider.thumbnail(for: libraryItem, size: CGSize(width: 104, height: 104), scale: 2)

        XCTAssertTrue(provider.cachedPreviewThumbnail(for: libraryItem) === image)
        XCTAssertNil(provider.cachedPreviewThumbnail(for: playlistItem), "Another valid root must not bypass invalidation")
        provider.allowThumbnails(forRootIDs: [playlistRoot])
        XCTAssertTrue(provider.cachedPreviewThumbnail(for: playlistItem) === image)
        await provider.shutdown()
    }

    func testPreviewNeverCrossesChangedOrUnknownFileRevisions() async throws {
        let image = try makeImage()
        let generator = PreviewThumbnailGenerator(image: image)
        let provider = QuickLookMediaThumbnailProvider(generator: generator, cacheMissDelay: .zero)
        _ = await provider.thumbnail(for: makeItem(), size: CGSize(width: 104, height: 104), scale: 2)

        for changed in [
            makeItem(fileSize: 101),
            makeItem(modificationDate: Date(timeIntervalSince1970: 2)),
            makeItem(fileIdentity: MediaFileIdentity(volumeIdentifier: Data([1]), fileIdentifier: Data([2]))),
            makeItem(path: "/tmp/ThumbnailPreviewOther/Clip.mp4"),
            makeItem(modificationDate: nil),
        ] {
            XCTAssertNil(provider.cachedPreviewThumbnail(for: changed))
        }
        let unknownRevision = makeItem(modificationDate: nil)
        _ = await provider.thumbnail(for: unknownRevision, size: CGSize(width: 104, height: 104), scale: 2)
        XCTAssertNil(provider.cachedPreviewThumbnail(for: unknownRevision))
        await provider.shutdown()
    }

    func testPurgeAndShutdownReleasePreviewAlongsideExactRepresentations() async throws {
        let image = try makeImage()
        let provider = QuickLookMediaThumbnailProvider(
            generator: PreviewThumbnailGenerator(image: image), cacheMissDelay: .zero
        )
        let item = makeItem()
        let size = CGSize(width: 104, height: 104)
        _ = await provider.thumbnail(for: item, size: size, scale: 2)
        XCTAssertTrue(provider.cachedPreviewThumbnail(for: item) === image)
        provider.purgeMemoryCache()
        XCTAssertNil(provider.cachedPreviewThumbnail(for: item))
        XCTAssertNil(provider.cachedThumbnail(for: item, size: size, scale: 2))
        _ = await provider.thumbnail(for: item, size: size, scale: 2)
        XCTAssertTrue(provider.cachedPreviewThumbnail(for: item) === image)
        await provider.shutdown()
        XCTAssertNil(provider.cachedPreviewThumbnail(for: item))
        XCTAssertNil(provider.cachedThumbnail(for: item, size: size, scale: 2))
    }

    private func makeItem(
        path: String = "/tmp/ThumbnailPreview/Clip.mp4", asFileRoot: Bool = false,
        fileSize: Int64 = 100, modificationDate: Date? = Date(timeIntervalSince1970: 1),
        fileIdentity: MediaFileIdentity? = nil
    ) -> LibraryMediaItem {
        let url = URL(fileURLWithPath: path)
        let root = asFileRoot ? url : url.deletingLastPathComponent()
        return LibraryMediaItem(
            rootURL: root, rootName: root.lastPathComponent,
            kind: asFileRoot ? .file : .folder, url: url, displayName: "Clip",
            relativePath: asFileRoot ? "" : url.lastPathComponent, relativeDirectory: "",
            creationDate: nil, modificationDate: modificationDate, fileSize: fileSize,
            fileIdentity: fileIdentity
        )
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class PreviewThumbnailGenerator: QuickLookThumbnailGenerating {
    let image: CGImage
    private(set) var generationCount = 0
    init(image: CGImage) { self.image = image }
    func generateImage(for request: QLThumbnailGenerator.Request) async throws -> CGImage {
        generationCount += 1
        return image
    }
    func cancel(_ request: QLThumbnailGenerator.Request) {}
}
