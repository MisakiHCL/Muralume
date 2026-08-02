import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacMediaFolderPicker: MediaSourceSelecting {
    private let localization: AppLocalizationController

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func selectVideos() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = MediaLibraryFilePolicy
            .supportedVideoExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = localized("library.video.picker.message")
        panel.prompt = localized("library.video.picker.prompt")

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    func selectFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = localized("library.folder.picker.message")
        panel.prompt = localized("library.folder.picker.prompt")

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }
}
