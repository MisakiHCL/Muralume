import Foundation

@MainActor
protocol MediaFolderSelecting: AnyObject {
    func selectFolders() -> [URL]
}
