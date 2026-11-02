import AppKit
import SwiftUI
import XCTest
@testable import Muralume

@MainActor
final class SubtitleFontPickerTests: XCTestCase {
    func testUserSelectionWritesFontAndSystemChoice() {
        var selection: String?
        var changes: [String?] = []
        let coordinator = SubtitleFontPicker.Coordinator(selection: Binding(
            get: { selection },
            set: { selection = $0; changes.append($0) }
        ))
        let button = makeButton()
        configure(button, families: ["Avenir", "Menlo"])
        button.target = coordinator
        button.action = #selector(SubtitleFontPicker.Coordinator.selectionChanged(_:))

        button.selectItem(at: 2)
        button.sendAction(button.action, to: button.target)
        XCTAssertEqual(selection, "Menlo")

        button.selectItem(at: 0)
        button.sendAction(button.action, to: button.target)
        XCTAssertNil(selection)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0], "Menlo")
        XCTAssertNil(changes[1])
    }

    func testSystemTitleCanMatchAFontFamilyWithoutLosingEitherChoice() {
        let button = makeButton()
        configure(button, families: ["System Font"], selection: "System Font")
        XCTAssertEqual(button.itemTitles, ["System Font", "System Font"])
        XCTAssertEqual(button.indexOfSelectedItem, 1)
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "System Font")

        configure(button, families: ["System Font"])
        XCTAssertEqual(button.indexOfSelectedItem, 0)
        XCTAssertNil(button.selectedItem?.representedObject)
    }

    func testLoadingAndMissingFontPreserveSelectionWithoutWritingPreferences() {
        var writes = 0
        let coordinator = SubtitleFontPicker.Coordinator(selection: Binding(
            get: { "Unlisted Font" },
            set: { _ in writes += 1 }
        ))
        let button = makeButton()
        button.target = coordinator
        button.action = #selector(SubtitleFontPicker.Coordinator.selectionChanged(_:))

        configure(button, families: [], selection: "Unlisted Font")
        XCTAssertEqual(button.itemTitles, ["System Font", "Unlisted Font"])
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Unlisted Font")

        configure(button, families: ["Avenir", "Menlo"], selection: "Unlisted Font")
        XCTAssertEqual(button.itemTitles, ["System Font", "Unlisted Font", "Avenir", "Menlo"])
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Unlisted Font")

        configure(button, families: ["Avenir", "Unlisted Font"], selection: "Unlisted Font")
        XCTAssertEqual(button.itemTitles, ["System Font", "Avenir", "Unlisted Font"])
        XCTAssertEqual(button.selectedItem?.representedObject as? String, "Unlisted Font")
        XCTAssertEqual(writes, 0)
    }

    func testOrdinaryAndLocalizationUpdatesReuseMenuItemsAndUpdateAccessibility() {
        let button = makeButton()
        configure(button, families: ["Avenir", "Menlo"], selection: "Menlo")
        let originalItems = button.itemArray

        configure(button, families: ["Avenir", "Menlo"], selection: "Avenir")
        XCTAssertTrue(zip(originalItems, button.itemArray).allSatisfy { $0 === $1 })
        XCTAssertEqual(button.selectedItem?.title, "Avenir")

        button.configure(
            fontFamilies: ["Avenir", "Menlo"], selection: nil,
            systemFontTitle: "系统字体", accessibilityLabel: "字幕字体", isEnabled: false
        )
        XCTAssertTrue(zip(originalItems, button.itemArray).allSatisfy { $0 === $1 })
        XCTAssertEqual(button.selectedItem?.title, "系统字体")
        XCTAssertEqual(button.accessibilityLabel(), "字幕字体")
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.intrinsicContentSize.width, NSView.noIntrinsicMetric)
    }

    private func makeButton() -> SubtitleFontPopUpButton {
        SubtitleFontPopUpButton(frame: .zero, pullsDown: false)
    }

    private func configure(
        _ button: SubtitleFontPopUpButton,
        families: [String],
        selection: String? = nil
    ) {
        button.configure(
            fontFamilies: families, selection: selection,
            systemFontTitle: "System Font", accessibilityLabel: "Font", isEnabled: true
        )
    }
}
