import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacExternalSubtitlePicker: ExternalSubtitleSelecting {
    private let localization: AppLocalizationController

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func selectSubtitle() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = ExternalSubtitlePolicy
            .supportedExtensions
            .sorted()
            .map { UTType(filenameExtension: $0) ?? UTType(importedAs: $0) }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = localization.localized(
            "player.tracks.external.picker.message"
        )
        panel.prompt = localization.localized(
            "player.tracks.external.picker.prompt"
        )
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }
}
