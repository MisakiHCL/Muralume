import AVFoundation
import Foundation

@MainActor
struct AVFoundationAssetMetadata {
    let isPlayable: Bool
    let duration: CMTime
    let videoTracks: [AVAssetTrack]
    let audioGroup: AVMediaSelectionGroup?
    let subtitleGroup: AVMediaSelectionGroup?
}

@MainActor
struct AVFoundationLoadedAsset {
    let asset: AVURLAsset
    let lease: MediaPlaybackURLLease
    let metadata: AVFoundationAssetMetadata
}

/// A cancelled caller can leave immediately, but the asset and its URL lease
/// remain owned by the single real worker until AVFoundation finishes unwinding.
/// Each engine has its own slot, so independent displays cannot cancel each other.
@MainActor
final class AVFoundationAssetLoadController {
    typealias AssetFactory = @MainActor (URL) -> AVURLAsset
    typealias MetadataLoader = @MainActor (AVURLAsset) async throws
        -> AVFoundationAssetMetadata

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var asset: AVURLAsset?

        func install(_ asset: AVURLAsset) throws {
            let cancelled = lock.withLock {
                self.asset = asset
                return isCancelled
            }
            if cancelled {
                asset.cancelLoading()
                throw CancellationError()
            }
        }

        func cancel() {
            let asset = lock.withLock {
                isCancelled = true
                return self.asset
            }
            asset?.cancelLoading()
        }

        var wasCancelled: Bool { lock.withLock { isCancelled } }
    }

    @MainActor
    private final class Request {
        let id: UUID
        let sourceURL: URL
        let cancellation: Cancellation
        var continuation: CheckedContinuation<AVFoundationLoadedAsset, Error>?

        init(
            id: UUID,
            sourceURL: URL,
            cancellation: Cancellation,
            continuation: CheckedContinuation<AVFoundationLoadedAsset, Error>
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.cancellation = cancellation
            self.continuation = continuation
        }

        func finish(_ result: Result<AVFoundationLoadedAsset, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private let assetFactory: AssetFactory
    private let metadataLoader: MetadataLoader
    private var running: Request?
    private var pending: Request?
    private var worker: Task<Void, Never>?

    init(
        assetFactory: @escaping AssetFactory = { AVURLAsset(url: $0) },
        metadataLoader: @escaping MetadataLoader = loadMetadata
    ) {
        self.assetFactory = assetFactory
        self.metadataLoader = metadataLoader
    }

    func load(_ sourceURL: URL) async throws -> AVFoundationLoadedAsset {
        let id = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            cancelAll()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(
                    id: id,
                    sourceURL: sourceURL,
                    cancellation: cancellation,
                    continuation: continuation
                )
                guard !cancellation.wasCancelled else {
                    request.finish(.failure(CancellationError()))
                    return
                }
                pending = request
                startPendingIfPossible()
            }
        } onCancel: {
            // This cancellation is asset-specific; a delayed actor callback
            // from an older caller must never cancel the next request's asset.
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func cancelAll() {
        if let pending {
            self.pending = nil
            pending.cancellation.cancel()
            pending.finish(.failure(CancellationError()))
        }
        if let running {
            running.cancellation.cancel()
            worker?.cancel()
            running.finish(.failure(CancellationError()))
        }
    }

    func drain() async {
        while let worker {
            await worker.value
        }
    }

    private func cancel(id: UUID) {
        if pending?.id == id, let pending {
            self.pending = nil
            pending.finish(.failure(CancellationError()))
        }
        if running?.id == id, let running {
            worker?.cancel()
            running.finish(.failure(CancellationError()))
        }
    }

    private func startPendingIfPossible() {
        guard worker == nil, let request = pending else { return }
        pending = nil
        running = request
        let assetFactory = assetFactory
        let metadataLoader = metadataLoader
        worker = Task { @MainActor [weak self, request] in
            let result: Result<AVFoundationLoadedAsset, Error>
            do {
                try Task.checkCancellation()
                let lease = try MediaPlaybackURLLease(sourceURL: request.sourceURL)
                defer { withExtendedLifetime(lease) {} }
                let asset = assetFactory(lease.url)
                let cancellation = request.cancellation
                try cancellation.install(asset)
                let metadata = try await withTaskCancellationHandler {
                    try await metadataLoader(asset)
                } onCancel: {
                    cancellation.cancel()
                }
                try Task.checkCancellation()
                result = .success(AVFoundationLoadedAsset(
                    asset: asset,
                    lease: lease,
                    metadata: metadata
                ))
            } catch {
                // cancelLoading may finish before the actor cancellation
                // callback; AVFoundation's cancellation NSError still means
                // this caller was superseded, rather than a playback failure.
                result = .failure(request.cancellation.wasCancelled
                    ? CancellationError() : error)
            }
            request.finish(result)
            guard let self else { return }
            running = nil
            worker = nil
            startPendingIfPossible()
        }
    }

    private static func loadMetadata(
        _ asset: AVURLAsset
    ) async throws -> AVFoundationAssetMetadata {
        async let playable = asset.load(.isPlayable)
        async let duration = asset.load(.duration)
        async let tracks = asset.loadTracks(withMediaType: .video)
        async let audioGroup = asset.loadMediaSelectionGroup(for: .audible)
        async let subtitleGroup = asset.loadMediaSelectionGroup(for: .legible)
        return try await AVFoundationAssetMetadata(
            isPlayable: playable,
            duration: duration,
            videoTracks: tracks,
            audioGroup: audioGroup,
            subtitleGroup: subtitleGroup
        )
    }
}
