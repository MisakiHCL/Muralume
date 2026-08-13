import Foundation

@MainActor
protocol DesktopDisplayTopologyProviding: AnyObject {
    var displaysDidChangeHandler:
        (([DesktopDisplayDescriptor]) -> Void)? { get set }

    func currentDisplays() -> [DesktopDisplayDescriptor]
    func startMonitoring()
    func stopMonitoring()
    func identifyDisplays()
}
