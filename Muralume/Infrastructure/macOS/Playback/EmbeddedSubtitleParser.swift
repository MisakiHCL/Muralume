import AVFoundation
import Foundation

enum EmbeddedSubtitlePolicy {
    static let maximumTrackCount = 32
    static let maximumSampleCount = 40_000
    static let maximumTimelineUTF8Bytes = 4 * 1_024 * 1_024
    // First-pass eligibility keeps the selected track while validating one
    // other track: at most 8 MiB of subtitle UTF-8 text, never all 32 tracks.
    static let maximumPreparationUTF8Bytes = maximumTimelineUTF8Bytes * 2
    static let textLengthPrefixByteCount = 2
    static let maximumUTF8BytesPerCharacter = 4
    static let maximumSampleBytes =
        (
            ExternalSubtitlePolicy.maximumCueCharacters
                * maximumUTF8BytesPerCharacter
        ) + textLengthPrefixByteCount
}

struct EmbeddedSubtitlePreparation: Sendable {
    let isEligible: Bool
    let timeline: SubtitleTimeline?
}

protocol EmbeddedSubtitleParsing: Sendable {
    func validate(_ url: URL, selectableLanguages: [String]) async throws -> Bool
    func prepare(
        _ url: URL, languageIdentifier: String, selectableLanguages: [String]
    ) async throws -> EmbeddedSubtitlePreparation
    func parse(
        _ url: URL, languageIdentifier: String, selectableLanguages: [String]
    ) async throws
        -> SubtitleTimeline?
}

extension EmbeddedSubtitleParsing {
    func prepare(
        _ url: URL, languageIdentifier: String, selectableLanguages: [String]
    ) async throws -> EmbeddedSubtitlePreparation {
        guard try await validate(url, selectableLanguages: selectableLanguages) else {
            return EmbeddedSubtitlePreparation(isEligible: false, timeline: nil)
        }
        let timeline = try await parse(
            url, languageIdentifier: languageIdentifier,
            selectableLanguages: selectableLanguages
        )
        return EmbeddedSubtitlePreparation(isEligible: true, timeline: timeline)
    }
}

enum EmbeddedSubtitleLanguage {
    static func primaryIdentifier(_ identifier: String?) -> String? {
        guard let identifier,
              let language = Locale(identifier: identifier.replacingOccurrences(
                of: "_", with: "-"
              )).language.languageCode?.identifier.lowercased(),
              language != "und" else { return nil }
        return language
    }
}

struct EmbeddedSubtitleParser: EmbeddedSubtitleParsing {
    let maximumTimelineUTF8Bytes: Int

    init(maximumTimelineUTF8Bytes: Int = EmbeddedSubtitlePolicy.maximumTimelineUTF8Bytes) {
        self.maximumTimelineUTF8Bytes = min(
            max(maximumTimelineUTF8Bytes, 0), EmbeddedSubtitlePolicy.maximumTimelineUTF8Bytes
        )
    }

    func parse(
        _ url: URL, languageIdentifier: String, selectableLanguages: [String]
    ) async throws
        -> SubtitleTimeline? {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let cancellation = EmbeddedSubtitleReadCancellation(asset: asset)
        return try await withTaskCancellationHandler {
            guard let tracks = try await eligibleTracks(
                in: asset, selectableLanguages: selectableLanguages
            ), let language = EmbeddedSubtitleLanguage.primaryIdentifier(languageIdentifier),
            let track = tracks.first(where: { $0.language == language })?.track else { return nil }
            try Task.checkCancellation()
            return try timeline(for: track, in: asset, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    func prepare(
        _ url: URL, languageIdentifier: String, selectableLanguages: [String]
    ) async throws -> EmbeddedSubtitlePreparation {
        try await inspect(
            url, selectedLanguage: EmbeddedSubtitleLanguage.primaryIdentifier(languageIdentifier),
            selectableLanguages: selectableLanguages
        )
    }

    func validate(_ url: URL, selectableLanguages: [String]) async throws -> Bool {
        try await inspect(url, selectedLanguage: nil,
                          selectableLanguages: selectableLanguages).isEligible
    }

    /// Preserve the existing global fallback while reading every sample once.
    /// Only the selected timeline survives each iteration; the other track is
    /// released immediately, bounding first-pass text to two per-track budgets.
    private func inspect(
        _ url: URL, selectedLanguage: String?, selectableLanguages: [String]
    ) async throws -> EmbeddedSubtitlePreparation {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let cancellation = EmbeddedSubtitleReadCancellation(asset: asset)
        return try await withTaskCancellationHandler {
            guard let tracks = try await eligibleTracks(
                in: asset, selectableLanguages: selectableLanguages
            ) else { return EmbeddedSubtitlePreparation(isEligible: false, timeline: nil) }
            var selectedTimeline: SubtitleTimeline?
            for entry in tracks {
                try Task.checkCancellation()
                let parsed = try autoreleasepool {
                    try timeline(for: entry.track, in: asset, cancellation: cancellation)
                }
                guard let parsed else {
                    return EmbeddedSubtitlePreparation(isEligible: false, timeline: nil)
                }
                if entry.language == selectedLanguage { selectedTimeline = parsed }
            }
            try Task.checkCancellation()
            return EmbeddedSubtitlePreparation(isEligible: true, timeline: selectedTimeline)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func eligibleTracks(
        in asset: AVURLAsset, selectableLanguages: [String]
    ) async throws -> [(track: AVAssetTrack, language: String)]? {
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
            .prefix(EmbeddedSubtitlePolicy.maximumTrackCount)
        guard !tracks.isEmpty, tracks.count == selectableLanguages.count else { return nil }
        let eligibleLanguages = Set(selectableLanguages)
        var foundLanguages: Set<String> = []
        var result: [(track: AVAssetTrack, language: String)] = []
        for track in tracks {
            try Task.checkCancellation()
            let extended = try await track.load(.extendedLanguageTag)
            let identifier: String?
            if let extended { identifier = extended }
            else { identifier = try await track.load(.languageCode) }
            guard let language = EmbeddedSubtitleLanguage.primaryIdentifier(identifier),
                  eligibleLanguages.contains(language),
                  foundLanguages.insert(language).inserted else { return nil }
            let formats = try await track.load(.formatDescriptions)
            guard formats.contains(where: {
                CMFormatDescriptionGetMediaSubType($0) == kCMSubtitleFormatType_3GText
            }) else { return nil }
            result.append((track, language))
        }
        return result
    }

    private func timeline(
        for track: AVAssetTrack,
        in asset: AVAsset,
        cancellation: EmbeddedSubtitleReadCancellation
    ) throws -> SubtitleTimeline? {
        let reader = try AVAssetReader(asset: asset)
        cancellation.install(reader)
        try Task.checkCancellation()
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
        var textByteCount = 0
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
            let cueByteCount = cue.text.utf8.count
            guard cueByteCount <= maximumTimelineUTF8Bytes - textByteCount else {
                return nil
            }
            textByteCount += cueByteCount
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

/// AVFoundation may be blocked waiting for another sample when cancellation
/// arrives. Cancel its reader/loading directly instead of waiting for a poll.
private final class EmbeddedSubtitleReadCancellation: @unchecked Sendable {
    private let asset: AVURLAsset
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var isCancelled = false

    init(asset: AVURLAsset) { self.asset = asset }

    func install(_ reader: AVAssetReader) {
        let cancelled = lock.withLock {
            self.reader = reader
            return isCancelled
        }
        if cancelled { reader.cancelReading() }
    }

    func cancel() {
        let reader = lock.withLock {
            isCancelled = true
            return self.reader
        }
        asset.cancelLoading()
        reader?.cancelReading()
    }
}
