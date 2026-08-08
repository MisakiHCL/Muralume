import Foundation

@MainActor
protocol MediaSourceSelecting: AnyObject {
    func selectSources() -> [URL]
}
