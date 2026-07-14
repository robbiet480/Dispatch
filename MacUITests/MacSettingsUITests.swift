import XCTest

/// Smoke coverage for the Mac Settings scene (⌘,): the four toolbar-tabbed
/// preference panes exist, and Data's **Delete All Data** flow still holds BOTH
/// gates — the scope choice (backups opt-in) and the typed-DELETE confirmation.
///
/// The typed-DELETE gate is the point of this test: it proves the "Delete
/// Everything" button really is disabled until the field reads exactly `DELETE`
/// on this macOS version (SwiftUI has not been consistent about re-evaluating a
/// `.disabled` alert button as its bound TextField changes). It never completes
/// a deletion — the flow is cancelled at the last gate.
final class MacSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsTabsAndDeleteAllDataGates() throws {
        let app = XCUIApplication()
        // Same fixture as the other Mac UI tests: mock sensors + an in-memory,
        // never-CloudKit store + demo data. Nothing this test touches can reach
        // real user data.
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--demo-data"]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "main window should appear")
        app.activate()

        // Open Settings by KEYBOARD. Clicking the app menu flakes in this repo
        // ("timed out while waiting for menu open notification" — MacScreenshotTests
        // hit exactly that); ⌘, is system-provided by the Settings scene.
        app.typeKey(",", modifierFlags: .command)

        // The four panes.
        for name in ["General", "Sync", "Data", "About"] {
            XCTAssertTrue(tab(app, name).waitForExistence(timeout: 15),
                          "Settings should offer a \(name) tab")
        }
        XCTAssertTrue(settingsWindow(app).waitForExistence(timeout: 15),
                      "the Settings window should appear")

        tab(app, "Data").click()

        let deleteAll = app.buttons["delete-all-data"]
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 15),
                      "Data pane should offer Delete All Data…")
        deleteAll.click()

        // Gate 1 — scope: keeping backups is a distinct button from wiping them,
        // and Cancel is always available. Take the safe path (data only).
        let scope = modal(app, containing: "Delete Data Only")
        XCTAssertTrue(scope.waitForExistence(timeout: 15),
                      "the scope alert should appear")
        XCTAssertTrue(scope.buttons["Delete Data Only"].exists,
                      "scope alert should offer Delete Data Only")
        XCTAssertTrue(scope.buttons["Also Delete Backups"].exists,
                      "scope alert should offer Also Delete Backups (backups opt-in)")
        XCTAssertTrue(scope.buttons["Cancel"].exists,
                      "scope alert should offer Cancel")
        scope.buttons["Delete Data Only"].click()

        // Gate 2 — typed DELETE. Empty field ⇒ the destructive button is disabled.
        let confirm = modal(app, containing: "Delete Everything")
        XCTAssertTrue(confirm.waitForExistence(timeout: 15),
                      "the type-to-confirm alert should appear")
        let field = confirmField(in: confirm)
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "delete-confirm-field should exist")

        let deleteEverything = confirm.buttons["Delete Everything"]
        XCTAssertTrue(deleteEverything.exists, "Delete Everything button should exist")
        XCTAssertFalse(deleteEverything.isEnabled,
                       "Delete Everything must be DISABLED while the confirmation field is empty")

        field.click()
        field.typeText("DELETE")

        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"),
                                  evaluatedWith: deleteEverything)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed,
                       "Delete Everything must become ENABLED once the field reads DELETE")

        // Never actually delete: back out at the last gate.
        confirm.buttons["Cancel"].click()
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 10),
                      "cancelling should return to the Data pane with nothing deleted")
        XCTAssertEqual(app.state, .runningForeground, "the app should still be running")
    }

    // MARK: - Element lookup
    //
    // The Settings TabView's tabs and SwiftUI's `.alert` surface under different
    // AppKit element types depending on the macOS release (radio buttons vs.
    // buttons; sheets vs. dialogs vs. alerts), so match by role-agnostic
    // descendant search rather than pinning one type.

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@ OR title == %@",
                                  name, name, name))
            .matching(NSPredicate(format:
                "elementType == %d OR elementType == %d OR elementType == %d",
                XCUIElement.ElementType.radioButton.rawValue,
                XCUIElement.ElementType.button.rawValue,
                XCUIElement.ElementType.tab.rawValue))
            .firstMatch
    }

    /// The Settings window: whichever window hosts the tabs (its title tracks the
    /// selected pane on some releases, so don't match on title).
    @MainActor
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(
            NSPredicate(format: "label == 'Data' OR identifier == 'Data' OR title == 'Data'")
        ).firstMatch
    }

    /// The alert surface hosting `label` — a SwiftUI `.alert` lands as a sheet on
    /// macOS, but has also come through as a dialog/alert.
    @MainActor
    private func modal(_ app: XCUIApplication, containing label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ OR title == %@", label, label)
        for surface in [app.sheets, app.dialogs, app.alerts] {
            let match = surface.containing(.button, identifier: label).firstMatch
            if match.exists { return match }
            let byPredicate = surface.containing(predicate).firstMatch
            if byPredicate.exists { return byPredicate }
        }
        // Fall back to whichever surface eventually materializes.
        return app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
    }

    @MainActor
    private func confirmField(in modal: XCUIElement) -> XCUIElement {
        let byIdentifier = modal.textFields["delete-confirm-field"]
        if byIdentifier.exists { return byIdentifier }
        return modal.textFields.firstMatch
    }
}
