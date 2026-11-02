import CoreText
import Foundation

enum SubtitleFontFamilyLoader {
    /// Core Text supports background enumeration. Only plain family names cross
    /// back to the UI; the system query and localized sort stay off the main actor.
    static func load(
        using enumerate: @escaping @Sendable () -> [String] = {
            CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        }
    ) async -> [String]? {
        let worker = Task.detached(priority: .utility) { () -> [String]? in
            guard !Task.isCancelled else { return nil }
            let families = enumerate()
            guard !Task.isCancelled else { return nil }
            let validFamilies = Set(families.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.count
                        <= SubtitleAppearancePreferences.maximumFontFamilyNameLength
            })
            let sorted = validFamilies.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return Task.isCancelled ? nil : sorted
        }
        return await withTaskCancellationHandler {
            let families = await worker.value
            return Task.isCancelled ? nil : families
        } onCancel: {
            worker.cancel()
        }
    }
}
