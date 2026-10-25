import AVFoundation
import CoreMedia
import Foundation

private enum VideoInformationLoadingPolicy {
    static let maximumTracksToInspect = 16
    static let maximumFormatDescriptionsPerTrack = 8
}

/// A cancelled caller returns promptly while its real metadata worker keeps
/// owning the asset and compatibility URL until AVFoundation has unwound.
/// Reentrant calls share one worker and retain only the latest pending request.
actor AVAssetVideoInformationLoader: VideoInformationLoading {
    typealias AssetFactory = @Sendable (URL) -> AVURLAsset
    typealias MetadataLoader = @Sendable (
        AVURLAsset, ResolvedMediaSource
    ) async throws -> VideoInformation

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

        func releaseAsset() {
            lock.withLock { asset = nil }
        }

        var wasCancelled: Bool { lock.withLock { isCancelled } }
    }

    private final class Request {
        let id: UUID
        let source: ResolvedMediaSource
        let cancellation: Cancellation
        var continuation: CheckedContinuation<VideoInformation, Error>?

        init(
            id: UUID,
            source: ResolvedMediaSource,
            cancellation: Cancellation,
            continuation: CheckedContinuation<VideoInformation, Error>
        ) {
            self.id = id
            self.source = source
            self.cancellation = cancellation
            self.continuation = continuation
        }

        func finish(_ result: Result<VideoInformation, Error>) {
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
        metadataLoader: @escaping MetadataLoader = loadInformation
    ) {
        self.assetFactory = assetFactory
        self.metadataLoader = metadataLoader
    }

    func information(
        for source: ResolvedMediaSource
    ) async throws -> VideoInformation {
        let id = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            // A task cancelled before entering the actor must not supersede
            // another caller's current or pending information request.
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = Request(
                    id: id,
                    source: source,
                    cancellation: cancellation,
                    continuation: continuation
                )
                guard !cancellation.wasCancelled else {
                    request.finish(.failure(CancellationError()))
                    return
                }
                supersedeRequests()
                pending = request
                startPendingIfPossible()
            }
        } onCancel: {
            // Do this synchronously: the actor may still be awaiting a blocked
            // AVFoundation operation. The callback only affects this asset.
            cancellation.cancel()
            Task { [weak self] in await self?.cancel(id: id) }
        }
    }

    /// Wait for actual workers, including cancelled operations which have not
    /// finished unwinding. Caller completion alone does not release the slot.
    func drainPendingWork() async {
        while let worker {
            await worker.value
        }
    }

    private func supersedeRequests() {
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

    private func cancel(id: UUID) {
        if let pending, pending.id == id {
            self.pending = nil
            pending.finish(.failure(CancellationError()))
        }
        if let running, running.id == id {
            worker?.cancel()
            running.finish(.failure(CancellationError()))
        }
    }

    private func startPendingIfPossible() {
        guard worker == nil, let request = pending else { return }
        pending = nil
        running = request
        worker = Task { await perform(request) }
    }

    private func perform(_ request: Request) async {
        let result: Result<VideoInformation, Error>
        do {
            try Task.checkCancellation()
            let access = request.source.url.startAccessingSecurityScopedResource()
            defer {
                if access { request.source.url.stopAccessingSecurityScopedResource() }
            }
            let lease = try MediaPlaybackURLLease(
                sourceURL: request.source.url
            )
            defer { lease.invalidate() }
            let asset = assetFactory(lease.url)
            let cancellation = request.cancellation
            try cancellation.install(asset)
            let information = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await metadataLoader(asset, request.source)
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            if cancellation.wasCancelled { throw CancellationError() }
            result = .success(information)
        } catch {
            // AVFoundation may produce its cancellation NSError before
            // the actor callback arrives; callers still see cancellation.
            result = .failure(request.cancellation.wasCancelled
                ? CancellationError() : error)
        }
        request.cancellation.releaseAsset()
        request.finish(result)
        running = nil
        worker = nil
        startPendingIfPossible()
    }

    private static func loadInformation(
        asset: AVURLAsset,
        source: ResolvedMediaSource
    ) async throws -> VideoInformation {
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()

        guard let primaryVideoTrack = videoTracks.first else {
            throw VideoInformationLoadingError.videoTrackUnavailable
        }

        let videoCodecs = try await codecNames(
            for: videoTracks,
            name: VideoInformationMetadataInterpreter.videoCodecName
        )
        try Task.checkCancellation()

        let naturalSize = try await primaryVideoTrack.load(.naturalSize)
        let preferredTransform = try await primaryVideoTrack.load(
            .preferredTransform
        )
        let nominalFrameRate = try await primaryVideoTrack.load(
            .nominalFrameRate
        )
        let estimatedDataRate = try await primaryVideoTrack.load(
            .estimatedDataRate
        )
        let primaryDescriptions = try await primaryVideoTrack.load(
            .formatDescriptions
        )
        try Task.checkCancellation()

        let primaryDescription = primaryDescriptions.first
        let colorMetadata = primaryDescription.map(
            VideoInformationMetadataInterpreter.colorMetadata
        )
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioCodecs = try await codecNames(
            for: audioTracks,
            name: VideoInformationMetadataInterpreter.audioCodecName
        )
        try Task.checkCancellation()

        let subtitleTrackCount = try await subtitleTrackCount(in: asset)
        let resourceValues = try? source.url.resourceValues(
            forKeys: [.fileSizeKey]
        )

        return VideoInformation(
            container: VideoInformationMetadataInterpreter.containerName(
                forFileExtension: source.url.pathExtension
            ),
            videoCodecs: videoCodecs,
            resolution: Self.resolution(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            ),
            duration: Self.durationInSeconds(duration),
            frameRate: nominalFrameRate > 0
                ? Double(nominalFrameRate)
                : nil,
            videoBitRate: estimatedDataRate > 0
                ? Double(estimatedDataRate)
                : nil,
            dynamicRange:
                VideoInformationMetadataInterpreter.dynamicRange(
                    videoCodecIdentifiers: primaryDescriptions.prefix(
                        VideoInformationLoadingPolicy
                            .maximumFormatDescriptionsPerTrack
                    ).map {
                        VideoInformationMetadataInterpreter.fourCC(
                            CMFormatDescriptionGetMediaSubType($0)
                        )
                    },
                    transferFunction: colorMetadata?.transferFunction
                ),
            colorSpace: VideoInformationMetadataInterpreter.colorSpace(
                colorPrimaries: colorMetadata?.colorPrimaries,
                yCbCrMatrix: colorMetadata?.yCbCrMatrix
            ),
            audioCodecs: audioCodecs,
            audioTrackCount: audioTracks.count,
            subtitleTrackCount: subtitleTrackCount,
            fileSize: resourceValues?.fileSize.map(Int64.init)
        )
    }

    private static func codecNames(
        for tracks: [AVAssetTrack],
        name: (String) -> String
    ) async throws -> [String] {
        var names: [String] = []
        for track in tracks.prefix(
            VideoInformationLoadingPolicy.maximumTracksToInspect
        ) {
            let descriptions = try await track.load(.formatDescriptions)
            for description in descriptions.prefix(
                VideoInformationLoadingPolicy
                    .maximumFormatDescriptionsPerTrack
            ) {
                let identifier = VideoInformationMetadataInterpreter.fourCC(
                    CMFormatDescriptionGetMediaSubType(description)
                )
                let codecName = name(identifier)
                if !names.contains(codecName) {
                    names.append(codecName)
                }
            }
            try Task.checkCancellation()
        }
        return names
    }

    private static func subtitleTrackCount(in asset: AVAsset) async throws -> Int {
        let subtitleTracks = try await asset.loadTracks(
            withMediaType: .subtitle
        )
        try Task.checkCancellation()
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        try Task.checkCancellation()
        let closedCaptionTracks = try await asset.loadTracks(
            withMediaType: .closedCaption
        )
        return subtitleTracks.count
            + textTracks.count
            + closedCaptionTracks.count
    }

    private static func resolution(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> VideoResolution? {
        let transformedRect = CGRect(
            origin: .zero,
            size: naturalSize
        )
        .applying(preferredTransform)
        .standardized
        let width = Int(abs(transformedRect.width).rounded())
        let height = Int(abs(transformedRect.height).rounded())
        guard width > 0, height > 0 else {
            return nil
        }
        return VideoResolution(width: width, height: height)
    }

    private static func durationInSeconds(_ duration: CMTime) -> TimeInterval? {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }
}

enum VideoInformationLoadingError: Error, Equatable {
    case videoTrackUnavailable
}

enum VideoInformationMetadataInterpreter {
    struct ColorMetadata: Equatable {
        let colorPrimaries: String?
        let transferFunction: String?
        let yCbCrMatrix: String?
    }

    static func containerName(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "f4v", "m4v", "mp4", "mpeg4", "mpg4":
            "MPEG-4"
        case "mov", "qt":
            "QuickTime"
        case "m2p", "mod", "mpe", "mpeg", "mpg", "vob":
            "MPEG Program Stream"
        case "m2t", "m2ts", "mts", "tod", "ts":
            "MPEG-2 Transport Stream"
        case "3gp", "3gpp":
            "3GPP"
        case "3g2", "3gp2":
            "3GPP2"
        case "avi", "divx", "xvid":
            "AVI"
        case "dif", "dv", "sdv":
            "DV"
        case "m1v":
            "MPEG-1 Video"
        case "m2v", "mp2v", "mpv":
            "MPEG-2 Video"
        case let value where !value.isEmpty:
            value.uppercased()
        default:
            nil
        }
    }

    static func videoCodecName(for identifier: String) -> String {
        switch identifier.lowercased() {
        case "avc1", "avc3":
            "H.264 / AVC"
        case "hvc1", "hev1":
            "HEVC / H.265"
        case "dvh1", "dvhe":
            "Dolby Vision / HEVC"
        case "av01":
            "AV1"
        case "vp09":
            "VP9"
        case "vp08":
            "VP8"
        case "mp4v":
            "MPEG-4 Video"
        case "ap4h", "ap4x":
            "Apple ProRes 4444"
        case "apch":
            "Apple ProRes 422 HQ"
        case "apcn":
            "Apple ProRes 422"
        case "apcs":
            "Apple ProRes 422 LT"
        case "apco":
            "Apple ProRes 422 Proxy"
        case "jpeg":
            "Motion JPEG"
        default:
            displayIdentifier(identifier)
        }
    }

    static func audioCodecName(for identifier: String) -> String {
        switch identifier.lowercased() {
        case "mp4a", "aac ", "aach", "aacl", "aacp":
            "AAC"
        case "alac":
            "Apple Lossless / ALAC"
        case "opus":
            "Opus"
        case "ac-3", "ac3 ":
            "Dolby Digital / AC-3"
        case "ec-3", "eac3":
            "Dolby Digital Plus / E-AC-3"
        case ".mp3", "mp3 ":
            "MP3"
        case "flac":
            "FLAC"
        case "lpcm":
            "Linear PCM"
        default:
            displayIdentifier(identifier)
        }
    }

    static func dynamicRange(
        videoCodecIdentifiers: [String],
        transferFunction: String?
    ) -> VideoDynamicRange {
        if videoCodecIdentifiers.contains(where: {
            ["dvh1", "dvhe"].contains($0.lowercased())
        }) {
            return .dolbyVision
        }

        let normalizedTransfer = transferFunction?.lowercased() ?? ""
        if normalizedTransfer.contains("hlg") {
            return .hlg
        }
        if normalizedTransfer.contains("2084")
            || normalizedTransfer.contains("pq") {
            return .hdr10
        }
        if normalizedTransfer.contains("709")
            || normalizedTransfer.contains("601")
            || normalizedTransfer.contains("gamma")
            || normalizedTransfer.contains("linear")
            || normalizedTransfer.contains("240") {
            return .sdr
        }
        return .unknown
    }

    static func colorSpace(
        colorPrimaries: String?,
        yCbCrMatrix: String?
    ) -> String? {
        let normalized = [colorPrimaries, yCbCrMatrix]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if normalized.contains("2020") {
            return "BT.2020"
        }
        if normalized.contains("p3") {
            return "Display P3"
        }
        if normalized.contains("709") {
            return "BT.709"
        }
        if normalized.contains("601")
            || normalized.contains("smpte_c")
            || normalized.contains("ebu_3213") {
            return "BT.601"
        }
        return nil
    }

    static func colorMetadata(
        from description: CMFormatDescription
    ) -> ColorMetadata {
        guard let extensionDictionary = CMFormatDescriptionGetExtensions(
            description
        ) else {
            return ColorMetadata(
                colorPrimaries: nil,
                transferFunction: nil,
                yCbCrMatrix: nil
            )
        }
        let extensions = extensionDictionary as NSDictionary
        return ColorMetadata(
            colorPrimaries: extensions[
                kCMFormatDescriptionExtension_ColorPrimaries
            ] as? String,
            transferFunction: extensions[
                kCMFormatDescriptionExtension_TransferFunction
            ] as? String,
            yCbCrMatrix: extensions[
                kCMFormatDescriptionExtension_YCbCrMatrix
            ] as? String
        )
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(format: "0x%08X", value)
    }

    private static func displayIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? identifier : trimmed.uppercased()
    }
}
