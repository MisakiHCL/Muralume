import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacMediaFolderPicker: MediaFolderSelecting {
    private let localization: AppLocalizationController

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func selectFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = localized("library.folder.picker.message")
        panel.prompt = localized("library.add.folder")

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }
}
