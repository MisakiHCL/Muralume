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
        panel.allowsMultipleSelection = allowsMultipleSelection(for: intent)
        panel.resolvesAliases = true
        panel.allowedContentTypes = allowedContentTypes(for: intent)
        panel.canChooseDirectories = canChooseDirectories(for: intent)
        panel.canChooseFiles = canChooseFiles(for: intent)
        panel.canCreateDirectories = false
        panel.message = message(for: intent)
        panel.prompt = localized(promptKey(for: intent))

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }

    private var supportedVideoContentTypes: [UTType] {
        SupportedVideoContentType.allCases.map { contentType in
            UTType(contentType.rawValue)
                ?? UTType(importedAs: contentType.rawValue)
        }
    }

    private func allowsMultipleSelection(
        for intent: MediaSourceSelectionIntent
    ) -> Bool {
        switch intent {
        case .addingMedia, .reauthorizingSources:
            true
        case .reauthorizingSource:
            false
        }
    }

    private func allowedContentTypes(
        for intent: MediaSourceSelectionIntent
    ) -> [UTType] {
        switch intent {
        case .addingMedia, .reauthorizingSources:
            [.folder] + supportedVideoContentTypes
        case let .reauthorizingSource(source):
            source.kind == .folder ? [.folder] : supportedVideoContentTypes
        }
    }

    private func canChooseDirectories(
        for intent: MediaSourceSelectionIntent
    ) -> Bool {
        switch intent {
        case .addingMedia, .reauthorizingSources:
            true
        case let .reauthorizingSource(source):
            source.kind == .folder
        }
    }

    private func canChooseFiles(for intent: MediaSourceSelectionIntent) -> Bool {
        switch intent {
        case .addingMedia, .reauthorizingSources:
            true
        case let .reauthorizingSource(source):
            source.kind == .file
        }
    }

    private func message(for intent: MediaSourceSelectionIntent) -> String {
        switch intent {
        case .addingMedia, .reauthorizingSources:
            localized(messageKey(for: intent))
        case let .reauthorizingSource(source):
            localization.localizedFormat(
                source.kind == .folder
                    ? "library.media.picker.reauthorize.folder.message"
                    : "library.media.picker.reauthorize.video.message",
                source.displayName
            )
        }
    }

    private func messageKey(for intent: MediaSourceSelectionIntent) -> String {
        switch intent {
        case .addingMedia:
            "library.media.picker.message"
        case .reauthorizingSources, .reauthorizingSource:
            "library.media.picker.reauthorize.message"
        }
    }

    private func promptKey(for intent: MediaSourceSelectionIntent) -> String {
        switch intent {
        case .addingMedia:
            "library.media.picker.prompt"
        case .reauthorizingSources, .reauthorizingSource:
            "library.media.picker.reauthorize.prompt"
        }
    }
}
