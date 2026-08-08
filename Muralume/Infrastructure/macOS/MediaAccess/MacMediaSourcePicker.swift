import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacMediaSourcePicker: MediaSourceSelecting {
    private let localization: AppLocalizationController

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func selectSources() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.folder] + MediaLibraryFilePolicy
            .supportedVideoExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = localized("library.media.picker.message")
        panel.prompt = localized("library.media.picker.prompt")

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }
}
