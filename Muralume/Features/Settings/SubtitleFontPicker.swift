import AppKit
import SwiftUI

/// Avoids constructing a SwiftUI view for every installed font.
struct SubtitleFontPicker: NSViewRepresentable {
    let fontFamilies: [String]
    @Binding var selection: String?
    let systemFontTitle: String
    let accessibilityLabel: String

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> SubtitleFontPopUpButton {
        let button = SubtitleFontPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier(MuralumeAccessibilityIdentifier.subtitleFontPicker)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: SubtitleFontPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.configure(
            fontFamilies: fontFamilies,
            selection: selection,
            systemFontTitle: systemFontTitle,
            accessibilityLabel: accessibilityLabel,
            isEnabled: isEnabled
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String?>

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        @objc
        func selectionChanged(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem >= 0 else {
                return
            }
            selection.wrappedValue = sender.selectedItem?.representedObject as? String
        }
    }
}

@MainActor
final class SubtitleFontPopUpButton: NSPopUpButton {
    private var configuredFontFamilies: [String]?
    private var configuredFallback: String?

    override var intrinsicContentSize: NSSize {
        // The parent fixes the width. Asking AppKit for its intrinsic size would
        // still measure every menu title to find an unused maximum width.
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: MuralumeTheme.Size.compactControl
        )
    }

    func configure(
        fontFamilies: [String],
        selection: String?,
        systemFontTitle: String,
        accessibilityLabel: String,
        isEnabled: Bool
    ) {
        let fallback = selection.flatMap {
            fontFamilies.contains($0) ? nil : $0
        }
        if configuredFontFamilies != fontFamilies || configuredFallback != fallback {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(NSMenuItem(title: systemFontTitle, action: nil, keyEquivalent: ""))
            for family in fallback.map({ [$0] + fontFamilies }) ?? fontFamilies {
                let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
                item.representedObject = family
                menu.addItem(item)
            }
            self.menu = menu
            configuredFontFamilies = fontFamilies
            configuredFallback = fallback
        } else {
            item(at: 0)?.title = systemFontTitle
        }

        let selectedIndex = selection.flatMap { selectedFamily in
            itemArray.firstIndex {
                $0.representedObject as? String == selectedFamily
            }
        } ?? 0
        selectItem(at: selectedIndex)
        self.isEnabled = isEnabled
        setAccessibilityLabel(accessibilityLabel)
    }
}
