import AVFoundation
import Foundation

enum EmbeddedSubtitlePolicy {
    static let maximumTrackCount = 32
    static let maximumSampleCount = 40_000
    static let textLengthPrefixByteCount = 2
    static let maximumUTF8BytesPerCharacter = 4
    static let maximumSampleBytes =
        (
            ExternalSubtitlePolicy.maximumCueCharacters
                * maximumUTF8BytesPerCharacter
        ) + textLengthPrefixByteCount
}

struct EmbeddedSubtitleTrackData: Equatable, Sendable {
    let languageIdentifier: String?
    let timeline: SubtitleTimeline?
}

struct EmbeddedSubtitleParser: Sendable {
    func parse(_ url: URL) async throws -> [EmbeddedSubtitleTrackData] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        var parsedTracks: [EmbeddedSubtitleTrackData] = []
        parsedTracks.reserveCapacity(
            min(tracks.count, EmbeddedSubtitlePolicy.maximumTrackCount)
        )

        for track in tracks.prefix(EmbeddedSubtitlePolicy.maximumTrackCount) {
            try Task.checkCancellation()
            let extendedLanguageTag = try await track.load(
                .extendedLanguageTag
            )
            let languageIdentifier: String?
            if let extendedLanguageTag {
                languageIdentifier = extendedLanguageTag
            } else {
                languageIdentifier = try await track.load(.languageCode)
            }
            let formatDescriptions = try await track.load(
                .formatDescriptions
            )
            guard formatDescriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0)
                    == kCMSubtitleFormatType_3GText
            }) else {
                parsedTracks.append(
                    EmbeddedSubtitleTrackData(
                        languageIdentifier: languageIdentifier,
                        timeline: nil
                    )
                )
                continue
            }

            parsedTracks.append(
                EmbeddedSubtitleTrackData(
                    languageIdentifier: languageIdentifier,
                    timeline: try timeline(for: track, in: asset)
                )
            )
        }
        return parsedTracks
    }

    private func timeline(
        for track: AVAssetTrack,
        in asset: AVAsset
    ) throws -> SubtitleTimeline? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            return nil
        }
        reader.add(output)
        guard reader.startReading() else {
            return nil
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var cues: [SubtitleCue] = []
        cues.reserveCapacity(256)
        var inspectedSampleCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard inspectedSampleCount
                    < EmbeddedSubtitlePolicy.maximumSampleCount else {
                return nil
            }
            inspectedSampleCount += 1
            guard let cue = cue(from: sampleBuffer) else {
                continue
            }
            guard cues.count < ExternalSubtitlePolicy.maximumCueCount else {
                return nil
            }
            cues.append(cue)
        }

        guard reader.status == .completed, !cues.isEmpty else {
            return nil
        }
        return SubtitleTimeline(cues: cues)
    }

    private func cue(from sampleBuffer: CMSampleBuffer) -> SubtitleCue? {
        let sampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        guard sampleSize >= EmbeddedSubtitlePolicy.textLengthPrefixByteCount,
              sampleSize <= EmbeddedSubtitlePolicy.maximumSampleBytes,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: sampleSize)
        let copyStatus = CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: sampleSize,
            destination: &bytes
        )
        guard copyStatus == kCMBlockBufferNoErr else {
            return nil
        }

        let declaredTextLength = (Int(bytes[0]) << 8) | Int(bytes[1])
        guard declaredTextLength > 0,
              declaredTextLength
                <= sampleSize
                    - EmbeddedSubtitlePolicy.textLengthPrefixByteCount else {
            return nil
        }
        let textStartIndex = EmbeddedSubtitlePolicy.textLengthPrefixByteCount
        let textBytes = Data(
            bytes[textStartIndex..<(textStartIndex + declaredTextLength)]
        )
        guard let decodedText = decode(textBytes) else {
            return nil
        }
        let text = sanitize(decodedText)
        guard !text.isEmpty else {
            return nil
        }

        let startTime = CMSampleBufferGetPresentationTimeStamp(
            sampleBuffer
        ).seconds
        let duration = CMSampleBufferGetDuration(sampleBuffer).seconds
        guard startTime.isFinite,
              duration.isFinite,
              startTime >= 0,
              duration > 0 else {
            return nil
        }
        return SubtitleCue(
            startTime: startTime,
            endTime: startTime + duration,
            text: String(
                text.prefix(ExternalSubtitlePolicy.maximumCueCharacters)
            )
        )
    }

    private func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFE, 0xFF]) {
            return String(
                data: data.dropFirst(2),
                encoding: .utf16BigEndian
            )
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(
                data: data.dropFirst(2),
                encoding: .utf16LittleEndian
            )
        }
        return String(data: data, encoding: .utf8)
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
