import AppKit
import XCTest
@testable import Muralume

@MainActor
final class NativeEditMenuTests: XCTestCase {
    func testEditMenuUsesNativeResponderActionsWithoutPlayerFocusGating() throws {
        let commandHandler = TestMainMenuCommandHandler()
        let controller = makeMainMenuController(commandHandler: commandHandler, mainWindow: NSWindow())
        let menu = try XCTUnwrap(controller.canonicalMenu.items.first { $0.title == "Edit" }?.submenu)
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertTrue(menu.autoenablesItems)
        XCTAssertEqual(items.map(\.title), ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        XCTAssertEqual(items.compactMap(\.action).map(NSStringFromSelector), ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["z", "z", "x", "c", "v", "a"])
        XCTAssertTrue(items.allSatisfy { $0.target == nil }, "Editing must follow the current first responder, including system panels")
        XCTAssertEqual(items[1].keyEquivalentModifierMask, [.command, .shift])
        for index in [0, 2, 3, 4, 5] { XCTAssertEqual(items[index].keyEquivalentModifierMask, [.command]) }
    }

    func testSelectAllMenuKeyEquivalentOperatesOnNativeMultipleSelectionTable() throws {
        let controller = makeMainMenuController(commandHandler: TestMainMenuCommandHandler(), mainWindow: NSWindow())
        let menu = try XCTUnwrap(controller.canonicalMenu.items.first { $0.title == "Edit" }?.submenu)
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

    func testEditMenuTitlesUseEachSupportedLanguage() throws {
        let titles: [(AppLanguage, String)] = [
            (.english, "Edit"), (.simplifiedChinese, "编辑"), (.traditionalChinese, "編輯"),
            (.japanese, "編集"), (.korean, "편집"), (.french, "Édition"),
            (.german, "Bearbeiten"), (.spanish, "Edición"), (.brazilianPortuguese, "Editar"), (.italian, "Modifica")
        ]
        for (language, title) in titles {
            let controller = MacMainMenuController(
                application: NSApp, localization: AppLocalizationController(initialLanguage: language),
                commandHandler: TestMainMenuCommandHandler(), mainWindow: NSWindow()
            )
            let menu = try XCTUnwrap(controller.canonicalMenu.items.first { $0.title == title }?.submenu)
            XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 6)
            XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.title.isEmpty && !$0.title.hasPrefix("menu.") })
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
