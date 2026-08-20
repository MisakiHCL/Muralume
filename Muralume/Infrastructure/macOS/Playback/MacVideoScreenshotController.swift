import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct VideoScreenshotRequest: Equatable, Sendable {
    let source: ResolvedMediaSource
    let time: TimeInterval
}

protocol VideoScreenshotGenerating: Sendable {
    func jpegData(for request: VideoScreenshotRequest) async throws -> Data
}

enum VideoScreenshotGenerationError: Error, Equatable {
    case frameUnavailable
    case encodingFailed
}

private enum VideoScreenshotPolicy {
    static let maximumPixelDimension: CGFloat = 8_192
    static let fallbackFrameRate: Float = 30
    static let timeScale: CMTimeScale = 600
    static let maximumBaseNameLength = 96
    static let jpegCompressionQuality = 0.9
}

actor AVAssetVideoScreenshotGenerator: VideoScreenshotGenerating {
    func jpegData(for request: VideoScreenshotRequest) async throws -> Data {
        let asset = AVURLAsset(url: request.source.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw VideoScreenshotGenerationError.frameUnavailable
        }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        try Task.checkCancellation()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.maximumSize = CGSize(
            width: VideoScreenshotPolicy.maximumPixelDimension,
            height: VideoScreenshotPolicy.maximumPixelDimension
        )

        let effectiveFrameRate = nominalFrameRate > 0
            ? nominalFrameRate
            : VideoScreenshotPolicy.fallbackFrameRate
        let frameTolerance = CMTime(
            seconds: 1 / Double(effectiveFrameRate),
            preferredTimescale: VideoScreenshotPolicy.timeScale
        )
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance

        let requestedTime = CMTime(
            seconds: max(request.time, 0),
            preferredTimescale: VideoScreenshotPolicy.timeScale
        )
        let cancellationBox = VideoScreenshotGeneratorCancellationBox(
            generator: generator
        )
        let image: CGImage
        do {
            image = try await withTaskCancellationHandler {
                try await generator.image(at: requestedTime).image
            } onCancel: {
                cancellationBox.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VideoScreenshotGenerationError.frameUnavailable
        }
        try Task.checkCancellation()

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoScreenshotGenerationError.encodingFailed
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality:
                VideoScreenshotPolicy.jpegCompressionQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoScreenshotGenerationError.encodingFailed
        }
        return encodedData as Data
    }
}

private final class VideoScreenshotGeneratorCancellationBox:
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

enum VideoScreenshotFilenameBuilder {
    static func filename(
        source: ResolvedMediaSource,
        time: TimeInterval
    ) -> String {
        let displayName = (source.displayName as NSString)
            .deletingPathExtension
        let sanitizedName = sanitizedBaseName(displayName)
        let totalSeconds = Int(max(time, 0).rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        let timestamp = String(
            format: "%02d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            hours,
            minutes,
            seconds
        )
        return "\(sanitizedName)-\(timestamp).jpg"
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        let invalidCharacters = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/:")
        )
        let sanitized = value.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(
            sanitized.prefix(VideoScreenshotPolicy.maximumBaseNameLength)
        )
        return bounded.isEmpty ? "Muralume" : bounded
    }
}

@MainActor
final class MacVideoScreenshotController: VideoScreenshotControlling {
    private let localization: AppLocalizationController
    private let generator: any VideoScreenshotGenerating
    private var captureTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private var activeSavePanel: NSSavePanel?

    init(
        localization: AppLocalizationController,
        generator: any VideoScreenshotGenerating =
            AVAssetVideoScreenshotGenerator()
    ) {
        self.localization = localization
        self.generator = generator
    }

    deinit {
        captureTask?.cancel()
    }

    func capture(
        source: ResolvedMediaSource,
        at time: TimeInterval
    ) {
        guard captureTask == nil else {
            return
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        let request = VideoScreenshotRequest(source: source, time: time)
        let suggestedFilename = VideoScreenshotFilenameBuilder.filename(
            source: source,
            time: time
        )
        let generator = generator

        captureTask = Task { [weak self] in
            do {
                let jpegData = try await generator.jpegData(for: request)
                try Task.checkCancellation()
                guard let self,
                      let destinationURL = await selectDestination(
                        suggestedFilename: suggestedFilename
                      ) else {
                    self?.finishCapture(generation: generation)
                    return
                }
                try Task.checkCancellation()
                try jpegData.write(to: destinationURL, options: .atomic)
            } catch is CancellationError {
                // Cancellation is expected during shutdown or a superseding
                // app lifecycle transition.
            } catch {
                guard !Task.isCancelled else {
                    self?.finishCapture(generation: generation)
                    return
                }
                self?.presentFailure()
            }
            self?.finishCapture(generation: generation)
        }
    }

    func cancel() {
        captureGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
        activeSavePanel?.cancel(nil)
        activeSavePanel = nil
    }

    private func selectDestination(
        suggestedFilename: String
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename
        panel.title = localization.localized("screenshot.save.title")
        panel.message = localization.localized("screenshot.save.message")
        panel.prompt = localization.localized("screenshot.save.prompt")
        activeSavePanel = panel
        defer {
            if activeSavePanel === panel {
                activeSavePanel = nil
            }
        }

        guard let window = NSApp.keyWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(
                    returning: response == .OK ? panel.url : nil
                )
            }
        }
    }

    private func presentFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localization.localized(
            "screenshot.error.title"
        )
        alert.informativeText = localization.localized(
            "screenshot.error.message"
        )
        alert.addButton(
            withTitle: localization.localized("action.ok")
        )
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func finishCapture(generation: UInt64) {
        guard generation == captureGeneration else {
            return
        }
        captureTask = nil
    }
}
