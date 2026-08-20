import Foundation

struct SubtitleSidecarDiscovery: ExternalSubtitleDiscovering {
    func discover(
        for mediaURL: URL,
        preferredLanguageCodes: [String]
    ) -> URL? {
        let directoryURL = mediaURL.deletingLastPathComponent()
        let mediaStem = mediaURL.deletingPathExtension().lastPathComponent
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }

        var candidates: [Candidate] = []
        var visitedCount = 0
        while let item = enumerator.nextObject() as? URL,
              visitedCount < ExternalSubtitlePolicy.maximumDirectoryEntries {
            if Task.isCancelled {
                return nil
            }
            visitedCount += 1
            let fileExtension = item.pathExtension.lowercased()
            guard ExternalSubtitlePolicy.supportedExtensions.contains(
                fileExtension
            ),
            (try? item.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile) == true else {
                continue
            }
            let candidateStem = item.deletingPathExtension().lastPathComponent
            guard candidateStem == mediaStem
                    || candidateStem.hasPrefix(mediaStem + ".") else {
                continue
            }
            let languageSuffix = candidateStem == mediaStem
                ? nil
                : String(candidateStem.dropFirst(mediaStem.count + 1))
            candidates.append(
                Candidate(
                    url: item,
                    rank: rank(
                        languageSuffix: languageSuffix,
                        preferredLanguageCodes: preferredLanguageCodes
                    )
                )
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.url.lastPathComponent.localizedStandardCompare(
                    rhs.url.lastPathComponent
                ) == .orderedAscending
            }
            return lhs.rank < rhs.rank
        }?.url
    }

    private func rank(
        languageSuffix: String?,
        preferredLanguageCodes: [String]
    ) -> Int {
        guard let languageSuffix else {
            return 0
        }
        let normalizedSuffix = normalize(languageSuffix)
        let matchesPreferredLanguage = preferredLanguageCodes.contains {
            let language = normalize($0)
            return normalizedSuffix == language
                || normalizedSuffix.hasPrefix(language + "-")
                || language.hasPrefix(normalizedSuffix + "-")
        }
        return matchesPreferredLanguage ? 1 : 2
    }

    private func normalize(_ languageCode: String) -> String {
        languageCode
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}

private struct Candidate {
    let url: URL
    let rank: Int
}
