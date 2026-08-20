import Foundation

struct SubtitleFileParser: SubtitleFileParsing {
    func parse(_ url: URL) throws -> SubtitleTimeline {
        try Task.checkCancellation()
        let data = try readBoundedData(from: url)
        let content = try decode(data)
        let cues = try parseCues(from: content)
        guard !cues.isEmpty else {
            throw ExternalSubtitleLoadFailure.invalidFormat
        }
        return SubtitleTimeline(cues: cues)
    }

    private func readBoundedData(from url: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                try? handle.close()
            }
            let data = try handle.read(
                upToCount: ExternalSubtitlePolicy.maximumFileBytes + 1
            ) ?? Data()
            guard data.count <= ExternalSubtitlePolicy.maximumFileBytes else {
                throw ExternalSubtitleLoadFailure.fileTooLarge
            }
            return data
        } catch let failure as ExternalSubtitleLoadFailure {
            throw failure
        } catch {
            throw ExternalSubtitleLoadFailure.cannotRead
        }
    }

    private func decode(_ data: Data) throws -> String {
        let decoded: String?
        if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard var decoded else {
            throw ExternalSubtitleLoadFailure.unsupportedEncoding
        }
        if decoded.first == "\u{FEFF}" {
            decoded.removeFirst()
        }
        return decoded
    }

    private func parseCues(from content: String) throws -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: "\n[ \\t]*\n+",
                with: "\n\n",
                options: .regularExpression
            )
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(min(blocks.count, 1_024))

        for block in blocks {
            try Task.checkCancellation()
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(
                where: { $0.contains("-->") }
            ) else {
                continue
            }
            let timing = try parseTiming(lines[timingIndex])
            let rawText = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            let cueText = sanitize(rawText)
            guard !cueText.isEmpty else {
                continue
            }
            cues.append(
                SubtitleCue(
                    startTime: timing.start,
                    endTime: timing.end,
                    text: String(
                        cueText.prefix(
                            ExternalSubtitlePolicy.maximumCueCharacters
                        )
                    )
                )
            )
            guard cues.count <= ExternalSubtitlePolicy.maximumCueCount else {
                throw ExternalSubtitleLoadFailure.tooManyCues
            }
        }
        return cues
    }

    private func parseTiming(
        _ line: String
    ) throws -> (start: TimeInterval, end: TimeInterval) {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let startToken = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .first,
              let endToken = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .first,
              let start = timestamp(String(startToken)),
              let end = timestamp(String(endToken)),
              end > start else {
            throw ExternalSubtitleLoadFailure.invalidFormat
        }
        return (start, end)
    }

    private func timestamp(_ value: String) -> TimeInterval? {
        let components = value
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last ?? ""),
              seconds >= 0, seconds < 60,
              let minutes = Double(components[components.count - 2]),
              minutes >= 0, minutes < 60 else {
            return nil
        }
        let hours: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]), parsedHours >= 0 else {
                return nil
            }
            hours = parsedHours
        } else {
            hours = 0
        }
        return (hours * 3_600) + (minutes * 60) + seconds
    }

    private func sanitize(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(
                of: "(?i)<br\\s*/?>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
