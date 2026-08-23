import AVFoundation
import CoreGraphics
import Foundation

protocol CompatibilityMediaThumbnailGenerating: Sendable {
    func image(
        for sourceURL: URL,
        size: CGSize,
        scale: CGFloat
    ) async throws -> CGImage
}

private enum CompatibilityThumbnailPolicy {
    static let preferredFrameTime: TimeInterval = 0.5
    static let maximumPixelDimension: CGFloat = 2_048
    static let timeScale: CMTimeScale = 600
}

actor AVAssetCompatibilityThumbnailGenerator:
    CompatibilityMediaThumbnailGenerating
{
    func image(
        for sourceURL: URL,
        size: CGSize,
        scale: CGFloat
    ) async throws -> CGImage {
        let sourceLease = try MediaPlaybackURLLease(sourceURL: sourceURL)
        defer { sourceLease.invalidate() }
        let asset = AVURLAsset(url: sourceLease.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else {
            throw CompatibilityThumbnailGenerationError.videoTrackUnavailable
        }
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.maximumSize = Self.maximumSize(
            requestedSize: size,
            scale: scale
        )
        let requestedTime = CMTime(
            seconds: Self.frameTime(duration: duration),
            preferredTimescale: CompatibilityThumbnailPolicy.timeScale
        )
        let cancellationBox = CompatibilityThumbnailCancellationBox(
            generator: generator
        )

        return try await withTaskCancellationHandler {
            try await generator.image(at: requestedTime).image
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    private static func maximumSize(
        requestedSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let effectiveScale = max(scale, 1)
        let width = max(requestedSize.width * effectiveScale, 1)
        let height = max(requestedSize.height * effectiveScale, 1)
        let longestDimension = max(width, height)
        let boundedScale = min(
            CompatibilityThumbnailPolicy.maximumPixelDimension
                / longestDimension,
            1
        )
        return CGSize(
            width: width * boundedScale,
            height: height * boundedScale
        )
    }

    private static func frameTime(duration: CMTime) -> TimeInterval {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            return 0
        }
        return min(
            CompatibilityThumbnailPolicy.preferredFrameTime,
            seconds / 2
        )
    }
}

private enum CompatibilityThumbnailGenerationError: Error {
    case videoTrackUnavailable
}

private final class CompatibilityThumbnailCancellationBox:
    @unchecked Sendable
{
    private let generator: AVAssetImageGenerator

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}
