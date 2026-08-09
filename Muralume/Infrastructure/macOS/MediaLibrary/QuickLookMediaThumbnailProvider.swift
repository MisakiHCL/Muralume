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
    typealias CacheMissDelayer = @MainActor (Duration) async throws -> Void

    private enum Policy {
        static let generatorVersion = 1
        // Quick Look cancellation is cooperative, so bound actual in-flight work.
        static let maximumConcurrentRequestCount = 4
        // Avoid starting video decoding for rows only crossed while scrolling.
        static let cacheMissDelay: Duration = .milliseconds(80)
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
        enum State: Equatable {
            case queued
            case running
            case finished
        }

        let cacheKey: CacheKey
        let fileURL: URL
        let size: CGSize
        let scale: CGFloat
        let cacheGeneration: UInt64
        let isCacheable: Bool
        var state: State = .queued
        var cancellation: CancellationBox?
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var task: Task<Void, Never>?
        weak var previousQueuedRequest: ActiveRequest?
        var nextQueuedRequest: ActiveRequest?

        init(
            cacheKey: CacheKey,
            fileURL: URL,
            size: CGSize,
            scale: CGFloat,
            cacheGeneration: UInt64,
            isCacheable: Bool
        ) {
            self.cacheKey = cacheKey
            self.fileURL = fileURL
            self.size = size
            self.scale = scale
            self.cacheGeneration = cacheGeneration
            self.isCacheable = isCacheable
        }
    }

    private struct RootDrainWaiter {
        let rootPath: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum ActiveRequestLookup {
        case missing
        case completed(CGImage?)
    }

    private let generator: any QuickLookThumbnailGenerating
    private let cacheMissDelay: Duration
    private let cacheMissDelayer: CacheMissDelayer
    private let maximumConcurrentRequestCount: Int
    private let cache = NSCache<CacheKey, ImageBox>()
    private var attachableRequests: [CacheKey: ActiveRequest] = [:]
    private var firstQueuedRequest: ActiveRequest?
    private var lastQueuedRequest: ActiveRequest?
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
            SystemQuickLookThumbnailGenerator(),
        cacheMissDelay: Duration? = nil,
        maximumConcurrentRequestCount: Int? = nil,
        cacheMissDelayer: @escaping CacheMissDelayer = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let effectiveMaximumConcurrentRequestCount =
            maximumConcurrentRequestCount
            ?? Policy.maximumConcurrentRequestCount
        precondition(effectiveMaximumConcurrentRequestCount > 0)

        self.generator = generator
        self.cacheMissDelay = cacheMissDelay ?? Policy.cacheMissDelay
        self.maximumConcurrentRequestCount =
            effectiveMaximumConcurrentRequestCount
        self.cacheMissDelayer = cacheMissDelayer
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
        let requestCacheGeneration = cacheGeneration
        if let cachedImage = cachedImage(
            for: cacheKey,
            isCacheable: isCacheable
        ) {
            return cachedImage
        }

        switch await attachToActiveRequestIfAvailable(
            cacheKey: cacheKey,
            rootPath: item.id.rootPath
        ) {
        case .completed(let image):
            return image
        case .missing:
            break
        }

        if let cachedImage = cachedImage(
            for: cacheKey,
            isCacheable: isCacheable
        ) {
            return cachedImage
        }

        if cacheMissDelay > .zero {
            do {
                try await cacheMissDelayer(cacheMissDelay)
            } catch {
                return nil
            }
        }
        guard !Task.isCancelled,
              !isShutDown,
              !invalidatedRootPaths.contains(item.id.rootPath) else {
            return nil
        }
        if let cachedImage = cachedImage(
            for: cacheKey,
            isCacheable: isCacheable
        ) {
            return cachedImage
        }

        return await enqueueThumbnailRequest(
            for: item,
            size: size,
            scale: effectiveScale,
            cacheKey: cacheKey,
            cacheGeneration: requestCacheGeneration,
            isCacheable: isCacheable
        )
    }

    private func cachedImage(
        for cacheKey: CacheKey,
        isCacheable: Bool
    ) -> CGImage? {
        guard isCacheable else {
            return nil
        }
        return cache.object(forKey: cacheKey)?.image
    }

    private func attachToActiveRequestIfAvailable(
        cacheKey: CacheKey,
        rootPath: String
    ) async -> ActiveRequestLookup {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled,
                  !isShutDown,
                  !invalidatedRootPaths.contains(rootPath) else {
                return .completed(nil)
            }
            guard let activeRequest = attachableRequests[cacheKey] else {
                return .missing
            }
            let image = await withCheckedContinuation { continuation in
                activeRequest.waiters[waiterID] = continuation
                requestByWaiterID[waiterID] = activeRequest
            }
            return .completed(image)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
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

        var queuedRequest = firstQueuedRequest
        while let activeRequest = queuedRequest {
            queuedRequest = activeRequest.nextQueuedRequest
            guard activeRequest.cacheKey.itemID.rootPath == rootPath else {
                continue
            }
            discardQueuedRequest(activeRequest)
        }

        let matchingRequests = runningRequests.values.filter {
            $0.cacheKey.itemID.rootPath == rootPath
        }

        for activeRequest in matchingRequests {
            detachWaiters(from: activeRequest)
            if attachableRequests[activeRequest.cacheKey] === activeRequest {
                attachableRequests[activeRequest.cacheKey] = nil
            }
            activeRequest.task?.cancel()
            activeRequest.cancellation?.cancel()
        }

        startQueuedRequestsIfPossible()

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

            while let activeRequest = firstQueuedRequest {
                discardQueuedRequest(activeRequest)
            }

            runningRequests.values.forEach { activeRequest in
                activeRequest.task?.cancel()
                activeRequest.cancellation?.cancel()
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
        cacheGeneration: UInt64,
        isCacheable: Bool
    ) async -> CGImage? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      !isShutDown,
                      !invalidatedRootPaths.contains(item.id.rootPath) else {
                    continuation.resume(returning: nil)
                    return
                }

                if let activeRequest = attachableRequests[cacheKey] {
                    activeRequest.waiters[waiterID] = continuation
                    requestByWaiterID[waiterID] = activeRequest
                    return
                }

                let activeRequest = ActiveRequest(
                    cacheKey: cacheKey,
                    fileURL: item.url,
                    size: size,
                    scale: scale,
                    cacheGeneration: cacheGeneration,
                    isCacheable: isCacheable
                )
                activeRequest.waiters[waiterID] = continuation
                attachableRequests[cacheKey] = activeRequest
                requestByWaiterID[waiterID] = activeRequest
                enqueue(activeRequest)
                startQueuedRequestsIfPossible()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func enqueue(_ activeRequest: ActiveRequest) {
        activeRequest.previousQueuedRequest = lastQueuedRequest
        activeRequest.nextQueuedRequest = nil
        lastQueuedRequest?.nextQueuedRequest = activeRequest
        lastQueuedRequest = activeRequest
        if firstQueuedRequest == nil {
            firstQueuedRequest = activeRequest
        }
    }

    private func removeFromQueue(_ activeRequest: ActiveRequest) {
        let previousRequest = activeRequest.previousQueuedRequest
        let nextRequest = activeRequest.nextQueuedRequest

        if let previousRequest {
            previousRequest.nextQueuedRequest = nextRequest
        } else {
            firstQueuedRequest = nextRequest
        }
        if let nextRequest {
            nextRequest.previousQueuedRequest = previousRequest
        } else {
            lastQueuedRequest = previousRequest
        }

        activeRequest.previousQueuedRequest = nil
        activeRequest.nextQueuedRequest = nil
    }

    private func discardQueuedRequest(_ activeRequest: ActiveRequest) {
        guard activeRequest.state == .queued else {
            return
        }

        removeFromQueue(activeRequest)
        activeRequest.state = .finished
        if attachableRequests[activeRequest.cacheKey] === activeRequest {
            attachableRequests[activeRequest.cacheKey] = nil
        }
        detachWaiters(from: activeRequest)
    }

    private func startQueuedRequestsIfPossible() {
        guard !isShutDown else {
            return
        }

        while runningRequests.count < maximumConcurrentRequestCount,
              let activeRequest = firstQueuedRequest {
            guard !activeRequest.waiters.isEmpty,
                  !invalidatedRootPaths.contains(
                    activeRequest.cacheKey.itemID.rootPath
                  ) else {
                discardQueuedRequest(activeRequest)
                continue
            }

            removeFromQueue(activeRequest)
            let request = QLThumbnailGenerator.Request(
                fileAt: activeRequest.fileURL,
                size: activeRequest.size,
                scale: activeRequest.scale,
                representationTypes: [
                    .lowQualityThumbnail,
                    .thumbnail
                ]
            )
            request.iconMode = false
            activeRequest.state = .running
            activeRequest.cancellation = CancellationBox(
                generator: generator,
                request: request
            )
            runningRequests[ObjectIdentifier(activeRequest)] = activeRequest
            activeRequest.task = Task { [weak self, weak activeRequest] in
                guard let self, let activeRequest else {
                    return
                }
                await generateThumbnail(for: activeRequest)
            }
        }
    }

    private func generateThumbnail(for activeRequest: ActiveRequest) async {
        guard !Task.isCancelled else {
            finishRequest(activeRequest, image: nil)
            return
        }
        guard let cancellation = activeRequest.cancellation else {
            finishRequest(activeRequest, image: nil)
            return
        }

        let image: CGImage?
        do {
            let generatedImage = try await withTaskCancellationHandler {
                try await generator.generateImage(
                    for: cancellation.request
                )
            } onCancel: {
                Task { @MainActor in
                    cancellation.cancel()
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

        switch activeRequest.state {
        case .queued:
            discardQueuedRequest(activeRequest)
        case .running:
            if attachableRequests[activeRequest.cacheKey] === activeRequest {
                attachableRequests[activeRequest.cacheKey] = nil
            }
            activeRequest.task?.cancel()
            activeRequest.cancellation?.cancel()
        case .finished:
            break
        }
    }

    private func finishRequest(
        _ activeRequest: ActiveRequest,
        image: CGImage?
    ) {
        guard activeRequest.state == .running else {
            return
        }

        activeRequest.state = .finished
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
        activeRequest.task = nil
        activeRequest.cancellation = nil
        startQueuedRequestsIfPossible()
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
