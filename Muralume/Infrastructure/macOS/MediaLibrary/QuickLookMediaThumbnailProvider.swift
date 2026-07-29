import CoreGraphics
import Foundation
import QuickLookThumbnailing

@MainActor
final class QuickLookMediaThumbnailProvider: MediaThumbnailProviding {
    private enum Policy {
        static let generatorVersion = 1
    }

    private final class CacheKey: NSObject {
        let itemID: LibraryMediaItem.ID
        let fileSize: Int64
        let modificationDate: Date?
        let pixelWidth: Int
        let pixelHeight: Int
        let generatorVersion: Int

        init(
            item: LibraryMediaItem,
            size: CGSize,
            scale: CGFloat
        ) {
            itemID = item.id
            fileSize = item.fileSize
            modificationDate = item.modificationDate
            pixelWidth = Int((size.width * scale).rounded(.up))
            pixelHeight = Int((size.height * scale).rounded(.up))
            generatorVersion = Policy.generatorVersion
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(itemID)
            hasher.combine(fileSize)
            hasher.combine(modificationDate)
            hasher.combine(pixelWidth)
            hasher.combine(pixelHeight)
            hasher.combine(generatorVersion)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else {
                return false
            }
            return itemID == other.itemID
                && fileSize == other.fileSize
                && modificationDate == other.modificationDate
                && pixelWidth == other.pixelWidth
                && pixelHeight == other.pixelHeight
                && generatorVersion == other.generatorVersion
        }
    }

    private final class ImageBox {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    @MainActor
    private final class CancellationBox {
        let generator: QLThumbnailGenerator
        let request: QLThumbnailGenerator.Request

        init(
            generator: QLThumbnailGenerator,
            request: QLThumbnailGenerator.Request
        ) {
            self.generator = generator
            self.request = request
        }

        func cancel() {
            generator.cancel(request)
        }
    }

    private let generator: QLThumbnailGenerator
    private let cache = NSCache<CacheKey, ImageBox>()
    private var activeRequests: [UUID: CancellationBox] = [:]
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    init(generator: QLThumbnailGenerator = .shared) {
        self.generator = generator
        cache.countLimit = AppConfiguration.mediaThumbnailCacheCountLimit
        cache.totalCostLimit = AppConfiguration.mediaThumbnailCacheByteLimit
    }

    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        guard !isShutDown else {
            return nil
        }

        let effectiveScale = max(scale, 1)
        let cacheKey = CacheKey(
            item: item,
            size: size,
            scale: effectiveScale
        )
        if let cachedImage = cache.object(forKey: cacheKey)?.image {
            return cachedImage
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: effectiveScale,
            representationTypes: [
                .lowQualityThumbnail,
                .thumbnail
            ]
        )
        request.iconMode = false
        let cancellation = CancellationBox(
            generator: generator,
            request: request
        )
        let requestID = UUID()
        activeRequests[requestID] = cancellation
        defer {
            finishRequest(requestID)
        }

        do {
            let representation = try await withTaskCancellationHandler {
                try await generator.generateBestRepresentation(for: request)
            } onCancel: {
                Task { @MainActor in
                    cancellation.cancel()
                }
            }
            try Task.checkCancellation()
            guard !isShutDown else {
                return nil
            }

            let image = representation.cgImage
            cache.setObject(
                ImageBox(image),
                forKey: cacheKey,
                cost: image.bytesPerRow * image.height
            )
            return image
        } catch {
            return nil
        }
    }

    func shutdown() async {
        isShutDown = true
        activeRequests.values.forEach { $0.cancel() }

        if !activeRequests.isEmpty {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        }

        cache.removeAllObjects()
    }

    private func finishRequest(_ requestID: UUID) {
        activeRequests[requestID] = nil
        guard activeRequests.isEmpty else {
            return
        }

        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
