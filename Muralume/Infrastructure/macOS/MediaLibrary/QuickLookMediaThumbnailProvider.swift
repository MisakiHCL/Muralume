import CoreGraphics
import Foundation
import QuickLookThumbnailing

@MainActor
protocol QuickLookThumbnailGenerating: AnyObject {
    func generateImage(
        for request: QLThumbnailGenerator.Request
    ) async throws -> CGImage

    func cancel(_ request: QLThumbnailGenerator.Request)
}

@MainActor
final class SystemQuickLookThumbnailGenerator: QuickLookThumbnailGenerating {
    private let generator: QLThumbnailGenerator

    init(generator: QLThumbnailGenerator = .shared) {
        self.generator = generator
    }

    func generateImage(
        for request: QLThumbnailGenerator.Request
    ) async throws -> CGImage {
        try await generator.generateBestRepresentation(for: request).cgImage
    }

    func cancel(_ request: QLThumbnailGenerator.Request) {
        generator.cancel(request)
    }
}

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
        let generator: any QuickLookThumbnailGenerating
        let request: QLThumbnailGenerator.Request
        private var isCancelled = false

        init(
            generator: any QuickLookThumbnailGenerating,
            request: QLThumbnailGenerator.Request
        ) {
            self.generator = generator
            self.request = request
        }

        func cancel() {
            guard !isCancelled else {
                return
            }
            isCancelled = true
            generator.cancel(request)
        }
    }

    @MainActor
    private final class ActiveRequest {
        let cacheKey: CacheKey
        let cancellation: CancellationBox
        let cacheGeneration: UInt64
        let isCacheable: Bool
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var task: Task<Void, Never>?

        init(
            cacheKey: CacheKey,
            cancellation: CancellationBox,
            cacheGeneration: UInt64,
            isCacheable: Bool
        ) {
            self.cacheKey = cacheKey
            self.cancellation = cancellation
            self.cacheGeneration = cacheGeneration
            self.isCacheable = isCacheable
        }
    }

    private struct RootDrainWaiter {
        let rootPath: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private let generator: any QuickLookThumbnailGenerating
    private let cache = NSCache<CacheKey, ImageBox>()
    private var attachableRequests: [CacheKey: ActiveRequest] = [:]
    // A cancelled request remains here until Quick Look actually returns.
    private var runningRequests: [ObjectIdentifier: ActiveRequest] = [:]
    private var requestByWaiterID: [UUID: ActiveRequest] = [:]
    private var rootDrainWaiters: [RootDrainWaiter] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var invalidatedRootPaths: Set<String> = []
    private var cacheGeneration: UInt64 = 0
    private var isShutDown = false

    init(
        generator: any QuickLookThumbnailGenerating =
            SystemQuickLookThumbnailGenerator()
    ) {
        self.generator = generator
        cache.countLimit = AppConfiguration.mediaThumbnailCacheCountLimit
        cache.totalCostLimit = AppConfiguration.mediaThumbnailCacheByteLimit
    }

    func thumbnail(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat
    ) async -> CGImage? {
        guard !isShutDown,
              !invalidatedRootPaths.contains(item.id.rootPath) else {
            return nil
        }

        let effectiveScale = max(scale, 1)
        let cacheKey = CacheKey(
            item: item,
            size: size,
            scale: effectiveScale
        )
        let isCacheable = item.modificationDate != nil
        if isCacheable,
           let cachedImage = cache.object(forKey: cacheKey)?.image {
            return cachedImage
        }

        return await enqueueThumbnailRequest(
            for: item,
            size: size,
            scale: effectiveScale,
            cacheKey: cacheKey,
            isCacheable: isCacheable
        )
    }

    func purgeMemoryCache() {
        cacheGeneration &+= 1
        cache.removeAllObjects()
    }

    func allowThumbnails(forRootIDs rootIDs: Set<MediaLibraryRoot.ID>) {
        invalidatedRootPaths.subtract(
            rootIDs.map(\.standardizedPath)
        )
    }

    func invalidateThumbnails(
        forRootID rootID: MediaLibraryRoot.ID
    ) async {
        purgeMemoryCache()
        let rootPath = rootID.standardizedPath
        invalidatedRootPaths.insert(rootPath)
        let matchingRequests = runningRequests.values.filter {
            $0.cacheKey.itemID.rootPath == rootPath
        }

        for activeRequest in matchingRequests {
            detachWaiters(from: activeRequest)
            if attachableRequests[activeRequest.cacheKey] === activeRequest {
                attachableRequests[activeRequest.cacheKey] = nil
            }
            activeRequest.task?.cancel()
            activeRequest.cancellation.cancel()
        }

        guard hasRunningRequest(forRootPath: rootPath) else {
            return
        }
        await withCheckedContinuation { continuation in
            rootDrainWaiters.append(
                RootDrainWaiter(
                    rootPath: rootPath,
                    continuation: continuation
                )
            )
        }
    }

    func shutdown() async {
        if !isShutDown {
            isShutDown = true
            cacheGeneration &+= 1
            cache.removeAllObjects()
            runningRequests.values.forEach { activeRequest in
                activeRequest.task?.cancel()
                activeRequest.cancellation.cancel()
            }
        }

        if !runningRequests.isEmpty {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        }

        cache.removeAllObjects()
    }

    private func enqueueThumbnailRequest(
        for item: LibraryMediaItem,
        size: CGSize,
        scale: CGFloat,
        cacheKey: CacheKey,
        isCacheable: Bool
    ) async -> CGImage? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isShutDown else {
                    continuation.resume(returning: nil)
                    return
                }

                if let activeRequest = attachableRequests[cacheKey] {
                    activeRequest.waiters[waiterID] = continuation
                    requestByWaiterID[waiterID] = activeRequest
                    return
                }

                let request = QLThumbnailGenerator.Request(
                    fileAt: item.url,
                    size: size,
                    scale: scale,
                    representationTypes: [
                        .lowQualityThumbnail,
                        .thumbnail
                    ]
                )
                request.iconMode = false
                let activeRequest = ActiveRequest(
                    cacheKey: cacheKey,
                    cancellation: CancellationBox(
                        generator: generator,
                        request: request
                    ),
                    cacheGeneration: cacheGeneration,
                    isCacheable: isCacheable
                )
                activeRequest.waiters[waiterID] = continuation
                attachableRequests[cacheKey] = activeRequest
                runningRequests[ObjectIdentifier(activeRequest)] = activeRequest
                requestByWaiterID[waiterID] = activeRequest
                activeRequest.task = Task { [weak self, weak activeRequest] in
                    guard let self, let activeRequest else {
                        return
                    }
                    await generateThumbnail(for: activeRequest)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func generateThumbnail(for activeRequest: ActiveRequest) async {
        guard !Task.isCancelled else {
            finishRequest(activeRequest, image: nil)
            return
        }

        let image: CGImage?
        do {
            let generatedImage = try await withTaskCancellationHandler {
                try await generator.generateImage(
                    for: activeRequest.cancellation.request
                )
            } onCancel: {
                Task { @MainActor in
                    activeRequest.cancellation.cancel()
                }
            }
            try Task.checkCancellation()
            image = generatedImage
        } catch {
            image = nil
        }
        finishRequest(activeRequest, image: image)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let activeRequest = requestByWaiterID.removeValue(
            forKey: waiterID
        ), let continuation = activeRequest.waiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        continuation.resume(returning: nil)

        guard activeRequest.waiters.isEmpty else {
            return
        }
        if attachableRequests[activeRequest.cacheKey] === activeRequest {
            attachableRequests[activeRequest.cacheKey] = nil
        }
        activeRequest.task?.cancel()
        activeRequest.cancellation.cancel()
    }

    private func finishRequest(
        _ activeRequest: ActiveRequest,
        image: CGImage?
    ) {
        runningRequests[ObjectIdentifier(activeRequest)] = nil
        if attachableRequests[activeRequest.cacheKey] === activeRequest {
            attachableRequests[activeRequest.cacheKey] = nil
        }

        let result = isShutDown ? nil : image
        if let result,
           activeRequest.isCacheable,
           activeRequest.cacheGeneration == cacheGeneration {
            cache.setObject(
                ImageBox(result),
                forKey: activeRequest.cacheKey,
                cost: result.bytesPerRow * result.height
            )
        }

        let waiters = activeRequest.waiters
        activeRequest.waiters.removeAll()
        for (waiterID, continuation) in waiters {
            requestByWaiterID[waiterID] = nil
            continuation.resume(returning: result)
        }
        resumeDrainWaitersIfNeeded()
    }

    private func detachWaiters(from activeRequest: ActiveRequest) {
        let waiters = activeRequest.waiters
        activeRequest.waiters.removeAll()
        for (waiterID, continuation) in waiters {
            requestByWaiterID[waiterID] = nil
            continuation.resume(returning: nil)
        }
    }

    private func hasRunningRequest(forRootPath rootPath: String) -> Bool {
        runningRequests.values.contains {
            $0.cacheKey.itemID.rootPath == rootPath
        }
    }

    private func resumeDrainWaitersIfNeeded() {
        var pendingRootWaiters: [RootDrainWaiter] = []
        for waiter in rootDrainWaiters {
            if hasRunningRequest(forRootPath: waiter.rootPath) {
                pendingRootWaiters.append(waiter)
            } else {
                waiter.continuation.resume()
            }
        }
        rootDrainWaiters = pendingRootWaiters

        if runningRequests.isEmpty {
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
