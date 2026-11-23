import AppKit
import XCTest
@testable import Muralume

@MainActor
final class NativeEditMenuTests: XCTestCase {
    func testHiddenEditingShortcutsUseNativeResponderActionsWithoutPlayerFocusGating() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(commandHandler: commandHandler, mainWindow: NSWindow())
        let menu = try XCTUnwrap(controller.canonicalMenu.items.first?.submenu)
        let items = menu.items.filter(\.isHidden)
        XCTAssertTrue(menu.autoenablesItems)
        XCTAssertTrue(items.allSatisfy(\.allowsKeyEquivalentWhenHidden))
        XCTAssertEqual(items.map(\.title), ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        XCTAssertEqual(items.compactMap(\.action).map(NSStringFromSelector), ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["z", "z", "x", "c", "v", "a"])
        XCTAssertTrue(items.allSatisfy { $0.target == nil }, "Editing must follow the current first responder, including system panels")
        XCTAssertEqual(
            items.map(\.keyEquivalentModifierMask),
            [.command, [.command, .shift], .command, .command, .command, .command]
        )
    }

    func testSelectAllMenuKeyEquivalentOperatesOnNativeMultipleSelectionTable() throws {
        let controller = makeMainMenuController(commandHandler: TestMainMenuCommandHandler(), mainWindow: NSWindow())
        let menu = try XCTUnwrap(controller.canonicalMenu.items.first?.submenu)
        let selectAll = try XCTUnwrap(menu.items.first { $0.action == #selector(NSResponder.selectAll(_:)) })
        let table = NSTableView()
        let rows = TestEditMenuRows()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = rows
        table.allowsMultipleSelection = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(table.performKeyEquivalent(with: event), "The table itself does not own the standard menu shortcut")
        XCTAssertEqual(table.numberOfSelectedRows, 1)
        XCTAssertNil(selectAll.target)
        // Keep this hosted unit test independent of whichever window is key.
        // The production nil target uses this same native responder action.
        selectAll.target = table
        defer { selectAll.target = nil }
        XCTAssertTrue(controller.canonicalMenu.performKeyEquivalent(with: event))
        XCTAssertEqual(table.numberOfSelectedRows, 3)
        withExtendedLifetime(rows) {}
    }

    func testHiddenEditingCommandsUseEachSupportedLanguage() throws {
        let keys = ["menu.undo", "menu.redo", "menu.cut", "menu.copy", "menu.paste", "menu.selectAll"]
        for language in AppLanguage.allCases where language != .system {
            let localization = AppLocalizationController(initialLanguage: language)
            let controller = MacMainMenuController(
                application: NSApp, localization: localization,
                commandHandler: TestMainMenuCommandHandler(), mainWindow: NSWindow()
            )
            let menu = try XCTUnwrap(controller.canonicalMenu.items.first?.submenu)
            let titles = menu.items.filter(\.isHidden).map(\.title)
            XCTAssertEqual(titles, keys.map { localization.localized($0) })
            XCTAssertTrue(titles.allSatisfy { !$0.isEmpty && !$0.hasPrefix("menu.") })
        }
    }

    private func makeMainMenuController(
        commandHandler: TestMainMenuCommandHandler, mainWindow: NSWindow
    ) -> MacMainMenuController {
        MacMainMenuController(
            application: NSApp,
            localization: AppLocalizationController(initialLanguage: .english),
            commandHandler: commandHandler,
            mainWindow: mainWindow
        )
    }
}

@MainActor
private final class TestEditMenuRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}
