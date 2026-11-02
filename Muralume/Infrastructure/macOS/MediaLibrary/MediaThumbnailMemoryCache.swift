import CoreGraphics
import Foundation

/// Session-local thumbnail storage. Both exact representations and reusable
/// previews share the existing count/byte budget; each alias is charged its full
/// image cost. No extra image cache or disk persistence is introduced. Purge,
/// root invalidation and shutdown discard both kinds of entries together.
/// The owning provider is private to this app session, with no cross-user or
/// cross-process sharing. NSCache may evict either representation under pressure.
@MainActor
final class MediaThumbnailMemoryCache {
    final class Key: NSObject {
        let itemID: LibraryMediaItem.ID
        let fileIdentity: MediaFileIdentity?
        let fileSize: Int64
        let modificationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let generatorVersion: Int

        init(
            item: LibraryMediaItem,
            size: CGSize,
            scale: CGFloat,
            generatorVersion: Int
        ) {
            itemID = item.id
            fileIdentity = item.fileIdentity
            fileSize = item.fileSize
            modificationDate = item.modificationDate
            pixelWidth = Int((size.width * scale).rounded(.up))
            pixelHeight = Int((size.height * scale).rounded(.up))
            self.generatorVersion = generatorVersion
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(itemID)
            hasher.combine(fileIdentity)
            hasher.combine(fileSize)
            hasher.combine(modificationDate)
            hasher.combine(pixelWidth)
            hasher.combine(pixelHeight)
            hasher.combine(generatorVersion)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else {
                return false
            }
            return itemID == other.itemID
                && fileIdentity == other.fileIdentity
                && fileSize == other.fileSize
                && modificationDate == other.modificationDate
                && pixelWidth == other.pixelWidth
                && pixelHeight == other.pixelHeight
                && generatorVersion == other.generatorVersion
        }
    }

    // A preview follows the file revision rather than one collection's root ID
    // or pixel dimensions. The provider still gates the requesting root's access.
    private final class PreviewKey: NSObject {
        let mediaPath: String
        let fileIdentity: MediaFileIdentity?
        let fileSize: Int64
        let modificationDate: Date?
        let generatorVersion: Int

        init(item: LibraryMediaItem, generatorVersion: Int) {
            mediaPath = item.id.standardizedMediaPath
            fileIdentity = item.fileIdentity
            fileSize = item.fileSize
            modificationDate = item.modificationDate
            self.generatorVersion = generatorVersion
        }

        init(key: Key) {
            mediaPath = key.itemID.standardizedMediaPath
            fileIdentity = key.fileIdentity
            fileSize = key.fileSize
            modificationDate = key.modificationDate
            generatorVersion = key.generatorVersion
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(mediaPath)
            hasher.combine(fileIdentity)
            hasher.combine(fileSize)
            hasher.combine(modificationDate)
            hasher.combine(generatorVersion)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? PreviewKey else { return false }
            return mediaPath == other.mediaPath && fileIdentity == other.fileIdentity
                && fileSize == other.fileSize && modificationDate == other.modificationDate
                && generatorVersion == other.generatorVersion
        }
    }

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let storage = NSCache<NSObject, ImageBox>()

    init() {
        storage.countLimit = AppConfiguration.mediaThumbnailCacheCountLimit
        storage.totalCostLimit = AppConfiguration.mediaThumbnailCacheByteLimit
    }

    func image(for key: Key) -> CGImage? { storage.object(forKey: key)?.image }

    /// This is a first-frame preview, not proof that an exact-size request is
    /// fulfilled. Missing or changed metadata never reuses a previous revision.
    func preview(for item: LibraryMediaItem, generatorVersion: Int) -> CGImage? {
        guard item.modificationDate != nil else { return nil }
        return storage.object(forKey: PreviewKey(item: item, generatorVersion: generatorVersion))?.image
    }

    func insert(_ image: CGImage, for key: Key) {
        guard key.modificationDate != nil else { return }
        storage.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        let previewKey = PreviewKey(key: key)
        if let previous = storage.object(forKey: previewKey)?.image,
           previous.width >= image.width && previous.height >= image.height { return }
        storage.setObject(ImageBox(image), forKey: previewKey, cost: image.bytesPerRow * image.height)
    }

    func removeAllObjects() { storage.removeAllObjects() }
}
