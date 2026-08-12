import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacMediaSourcePicker: MediaSourceSelecting {
    private let localization: AppLocalizationController

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func selectSources(for intent: MediaSourceSelectionIntent) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.folder]
            + SupportedVideoContentType.allCases.map { contentType in
                UTType(contentType.rawValue)
                    ?? UTType(importedAs: contentType.rawValue)
            }
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = localized(messageKey(for: intent))
        panel.prompt = localized(promptKey(for: intent))

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }

    private func messageKey(for intent: MediaSourceSelectionIntent) -> String {
        switch intent {
        case .addingMedia:
            "library.media.picker.message"
        case .reauthorizingSources:
            "library.media.picker.reauthorize.message"
        }
    }

    private func promptKey(for intent: MediaSourceSelectionIntent) -> String {
        switch intent {
        case .addingMedia:
            "library.media.picker.prompt"
        case .reauthorizingSources:
            "library.media.picker.reauthorize.prompt"
        }
    }
}
