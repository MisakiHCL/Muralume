import AppKit
import XCTest

final class SourceHealthUITests: XCTestCase {
    private enum Identifier {
        static let addMedia = "muralume.add-media"
        static let editLibrary = "muralume.edit-library"
        static let librarySummary = "muralume.library-summary"
        static let sourceEditor = "muralume.source-editor"
        static let sourceRowPrefix = "muralume.source-row."
        static let sourceHealthPrefix = "muralume.source-health."
        static let sourceLastRefreshPrefix = "muralume.source-last-refresh."
    }

    private enum Timeout {
        static let control: TimeInterval = 5
        static let scan: TimeInterval = 30
    }

    @MainActor
    func testEmptyOwnedFolderShowsHealthRefreshTimeAndFullPath() throws {
        let application = try MuralumeUITestSession.makeApplication(for: type(of: self))
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MuralumeSourceHealthUITests-\(UUID().uuidString)", isDirectory: true
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
        defer {
            removeOwnedSourceIfPresent(sourceURL, in: application)
            if application.state != .notRunning { application.terminate() }
            try? FileManager.default.removeItem(at: sourceURL)
        }
        application.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-settings.app-language", "en",
            "-media-library.source-records", "", "-media-library.root-bookmarks", ""
        ]
        try MuralumeUITestSession.launch(application, for: type(of: self))
        application.activate()
        _ = try XCTUnwrap(
            application.wait(for: .runningForeground, timeout: Timeout.control) ? true : nil
        )
        try waitForText("0 videos, 0 media sources", on: element(Identifier.librarySummary, in: application))
        try importFolder(sourceURL, in: application)
        try waitForText(
            "0 videos, 1 media source", on: element(Identifier.librarySummary, in: application),
            timeout: Timeout.scan
        )
        try require(element(Identifier.editLibrary, in: application)).click()
        let editor = try require(element(Identifier.sourceEditor, in: application))
        let row = try require(element(Identifier.sourceRowPrefix + sourceURL.path, in: application))
        let health = try require(element(Identifier.sourceHealthPrefix + sourceURL.path, in: application))
        let announcedStatus = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            sourceURL.lastPathComponent, "Up to date"
        ), object: health)
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [announcedStatus], timeout: Timeout.control) == .completed ? true : nil,
            "The source name and health must both be announced to VoiceOver"
        )
        let refreshed = try require(element(Identifier.sourceLastRefreshPrefix + sourceURL.path, in: application))
        let successfulRefresh = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "title BEGINSWITH %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Last successful refresh: ", "Last successful refresh: ", "Last successful refresh: "
            ), object: refreshed
        )
        _ = try XCTUnwrap(
            XCTWaiter.wait(for: [successfulRefresh], timeout: Timeout.control) == .completed ? true : nil,
            "A complete successful scan must show its observed refresh time"
        )
        let path = try require(row.descendants(matching: .staticText).matching(displayedText(sourceURL.path)).firstMatch)
        XCTAssertTrue(path.isHittable)
        editor.hover()
        path.hover()
        _ = try require(application.helpTags.firstMatch)
        // Move away so the tooltip does not cover the row's removal control.
        editor.hover()
        let remove = try require(row.buttons.matching(displayedText("Remove")).firstMatch)
        XCTAssertTrue(remove.isEnabled)
        remove.click()
        try require(application.sheets.firstMatch.buttons.matching(displayedText("Remove Folder")).firstMatch).click()
        _ = try XCTUnwrap(row.waitForNonExistence(timeout: Timeout.control) ? true : nil)
        try waitForText("0 videos, 0 media sources", on: element(Identifier.librarySummary, in: application))
    }

    @MainActor
    private func importFolder(_ url: URL, in application: XCUIApplication) throws {
        try MuralumeUITestInputSource.withASCIILayout { inputSource in
            try require(element(Identifier.addMedia, in: application)).click()
            let picker = application.dialogs.firstMatch
            defer {
                let goTo = application.sheets["GoToWindow"]
                let closeGoTo = goTo.buttons["CloseButton"]
                if closeGoTo.exists { closeGoTo.click() }
                let cancel = picker.buttons.matching(NSPredicate(
                    format: "title == %@ OR label == %@", "Cancel", "Cancel"
                )).firstMatch
                if picker.exists, cancel.exists, cancel.isEnabled { cancel.click() }
            }
            _ = try require(picker)
            application.typeKey("g", modifierFlags: [.command, .shift])
            let goToWindow = try require(application.sheets["GoToWindow"])
            let field: XCUIElement
            if application.textFields["PathTextField"].waitForExistence(timeout: Timeout.control) {
                field = application.textFields["PathTextField"]
            } else if application.comboBoxes.firstMatch.waitForExistence(timeout: Timeout.control) {
                field = application.comboBoxes.firstMatch
            } else {
                field = try require(application.textFields.matching(
                    NSPredicate(format: "hasKeyboardFocus == true")
                ).firstMatch)
            }
            try replaceWithLiteralPath(url.path, in: field, application: application)
            field.click()
            try inputSource.prepareForConfirmation()
            field.typeKey(.return, modifierFlags: [])
            if !goToWindow.waitForNonExistence(timeout: Timeout.control), field.exists {
                field.click()
                try inputSource.prepareForConfirmation()
                field.typeKey(.return, modifierFlags: [])
            }
            _ = try XCTUnwrap(
                goToWindow.waitForNonExistence(timeout: Timeout.control) ? true : nil,
                "Go to Folder must finish selecting the test-owned empty directory"
            )
            try require(picker.buttons.matching(identifier: "OKButton").firstMatch).click()
            _ = try XCTUnwrap(picker.waitForNonExistence(timeout: Timeout.control) ? true : nil)
        }
    }

    @MainActor
    private func replaceWithLiteralPath(
        _ path: String, in field: XCUIElement, application: XCUIApplication
    ) throws {
        field.click()
        field.typeKey(.leftArrow, modifierFlags: .command)
        field.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        field.typeKey(.delete, modifierFlags: [])
        try waitForValue("", on: field)
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let originalItems = try (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                let data = try XCTUnwrap(item.data(forType: type), "The clipboard must be preserved before path input")
                _ = try XCTUnwrap(copy.setData(data, forType: type) ? true : nil)
            }
            return copy
        }
        _ = try XCTUnwrap(pasteboard.changeCount == originalChangeCount ? true : nil)
        pasteboard.clearContents()
        var ownedChangeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                if !originalItems.isEmpty {
                    XCTAssertTrue(pasteboard.writeObjects(originalItems))
                }
            }
        }
        let written = pasteboard.setString(path, forType: .string)
        ownedChangeCount = pasteboard.changeCount
        _ = try XCTUnwrap(written ? true : nil)
        field.rightClick()
        // The emptied editor's first enabled action is Paste. Use native
        // keyboard navigation even if its menu is outside XCTest's app tree.
        application.typeKey(.home, modifierFlags: [])
        application.typeKey(.return, modifierFlags: [])
        try waitForValue(path, on: field)
    }

    @MainActor
    private func removeOwnedSourceIfPresent(_ url: URL, in application: XCUIApplication) {
        guard application.state != .notRunning else { return }
        let pendingConfirmation = application.sheets.firstMatch.buttons.matching(displayedText("Remove Folder")).firstMatch
        if pendingConfirmation.exists {
            pendingConfirmation.click()
            return
        }
        let cancel = application.dialogs.firstMatch.buttons.matching(displayedText("Cancel")).firstMatch
        if cancel.exists { cancel.click() }
        let editor = element(Identifier.sourceEditor, in: application)
        if !editor.exists {
            let edit = element(Identifier.editLibrary, in: application)
            guard edit.exists && edit.isEnabled && edit.isHittable else { return }
            edit.click()
        }
        let row = element(Identifier.sourceRowPrefix + url.path, in: application)
        guard row.waitForExistence(timeout: Timeout.control) else { return }
        let remove = row.buttons.matching(displayedText("Remove")).firstMatch
        guard remove.exists && remove.isEnabled else { return }
        remove.click()
        let confirmation = application.sheets.firstMatch.buttons.matching(displayedText("Remove Folder")).firstMatch
        guard confirmation.waitForExistence(timeout: Timeout.control) else { return }
        confirmation.click()
        _ = row.waitForNonExistence(timeout: Timeout.control)
    }

    private func displayedText(_ text: String) -> NSPredicate {
        NSPredicate(format: "title == %@ OR label == %@ OR value == %@", text, text, text)
    }

    @MainActor
    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        // Path-based identifiers may exceed XCTest's 128-character convenience
        // query limit; an exact predicate preserves the complete identity.
        application.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }

    @MainActor
    private func require(_ element: XCUIElement) throws -> XCUIElement {
        try XCTUnwrap(
            element.waitForExistence(timeout: Timeout.control) ? element : nil,
            "Expected the source-health UI control to exist"
        )
    }

    @MainActor
    private func waitForText(
        _ text: String, on element: XCUIElement, timeout: TimeInterval = Timeout.control
    ) throws {
        _ = try require(element)
        let expected = XCTNSPredicateExpectation(predicate: displayedText(text), object: element)
        _ = try XCTUnwrap(XCTWaiter.wait(for: [expected], timeout: timeout) == .completed ? true : nil)
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) throws {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        _ = try XCTUnwrap(XCTWaiter.wait(for: [expected], timeout: Timeout.control) == .completed ? true : nil)
    }
}
