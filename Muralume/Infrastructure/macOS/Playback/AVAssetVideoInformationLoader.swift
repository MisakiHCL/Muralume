import AVFoundation
import CoreMedia
import Foundation

private enum VideoInformationLoadingPolicy {
    static let maximumTracksToInspect = 16
    static let maximumFormatDescriptionsPerTrack = 8
}

actor AVAssetVideoInformationLoader: VideoInformationLoading {
    func information(
        for source: ResolvedMediaSource
    ) async throws -> VideoInformation {
        let asset = AVURLAsset(url: source.url)
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

    private func codecNames(
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

    private func subtitleTrackCount(in asset: AVAsset) async throws -> Int {
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
        case "mp4", "m4v":
            "MPEG-4"
        case "mov", "qt":
            "QuickTime"
        case "mpg", "mpeg", "mpe":
            "MPEG Program Stream"
        case "m2t", "m2ts", "mts", "ts":
            "MPEG-2 Transport Stream"
        case "3gp", "3gpp":
            "3GPP"
        case "3g2", "3gp2":
            "3GPP2"
        case "avi":
            "AVI"
        case "dif", "dv", "sdv":
            "DV"
        case "m1v":
            "MPEG-1 Video"
        case "m2v":
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
        return .sdr
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
