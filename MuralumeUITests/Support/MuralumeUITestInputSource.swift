import Carbon
import Foundation
import XCTest

/// Uses an already enabled keyboard layout for native file-panel input only.
/// It never enables sources or writes keyboard preferences.
@MainActor
enum MuralumeUITestInputSource {
    enum InputSourceError: Error, LocalizedError {
        case unavailableLayout
        case selectionFailed
        case selectionChanged

        nonisolated var errorDescription: String? {
            switch self {
            case .unavailableLayout:
                "The UI test requires an enabled, selectable ASCII keyboard layout."
            case .selectionFailed:
                "The UI test could not temporarily select an ASCII keyboard layout."
            case .selectionChanged:
                "The input source changed during native file-panel input; the test stopped without overriding it."
            }
        }
    }

    @MainActor
    final class Selection {
        fileprivate let identifier: String
        private let originalIdentifier: String
        private let layout: TISInputSource

        fileprivate init(identifier: String, originalIdentifier: String, layout: TISInputSource) {
            self.identifier = identifier
            self.originalIdentifier = originalIdentifier
            self.layout = layout
        }

        func verifySelected() throws {
            guard MuralumeUITestInputSource.currentIdentifier() == identifier else {
                XCTFail("The temporary ASCII keyboard layout is not selected; native path confirmation was not sent.")
                throw InputSourceError.selectionChanged
            }
        }

        /// Call only after activating the native path field. AppKit can restore
        /// that document's original input source when its editor gains focus.
        func prepareForConfirmation() throws {
            let current = MuralumeUITestInputSource.currentIdentifier()
            if current == identifier { return }
            guard current == originalIdentifier else {
                XCTFail("An unexpected input-source change interrupted native path confirmation. The new selection was preserved.")
                throw InputSourceError.selectionChanged
            }
            guard TISSelectInputSource(layout) == noErr else {
                XCTFail("The ASCII keyboard layout could not be reselected for native path confirmation.")
                throw InputSourceError.selectionFailed
            }
            try verifySelected()
        }
    }

    static func withASCIILayout<Result>(
        _ operation: @MainActor (Selection) throws -> Result
    ) throws -> Result {
        guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let originalID = identifier(original), let layoutID = identifier(layout),
              property(layout, kTISPropertyInputSourceType) as? String == kTISTypeKeyboardLayout as String,
              property(layout, kTISPropertyInputSourceIsASCIICapable) as? Bool == true,
              property(layout, kTISPropertyInputSourceIsEnabled) as? Bool == true,
              property(layout, kTISPropertyInputSourceIsSelectCapable) as? Bool == true else {
            throw InputSourceError.unavailableLayout
        }
        let selection = Selection(identifier: layoutID, originalIdentifier: originalID, layout: layout)
        let status = TISSelectInputSource(layout)
        defer {
            // Restore only while the temporary layout is still selected, so
            // a newer input-source choice made by the user is left untouched.
            if originalID != layoutID, currentIdentifier() == layoutID {
                XCTAssertEqual(
                    TISSelectInputSource(original), noErr,
                    "The UI test must restore its temporary input-source selection"
                )
            }
        }
        guard status == noErr else { throw InputSourceError.selectionFailed }
        try selection.verifySelected()
        return try operation(selection)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID) as? String
    }

    private static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }
}
