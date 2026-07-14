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

        // Witness for "nothing was deleted": the dashboard's report count. A wipe
        // drives this to 0 (the reseed restores default QUESTIONS, never reports),
        // so re-reading it after the flow is what actually proves the cancel held.
        // Asserting the Delete button still exists would pass even after a wipe.
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 15),
                      "report-count label should exist")
        guard let reportsBefore = reportCount(countText(countLabel)), reportsBefore > 0 else {
            XCTFail("demo data should seed reports; got '\(countText(countLabel))'")
            return
        }

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
        // Danger Zone is the last section, so on a short display it sits below
        // the fold — and macOS XCUI does not scroll a click target into view,
        // it just fails "Not hittable". Scroll first (no-op when it's visible).
        scrollIntoView(deleteAll, in: settingsWindow(app))
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

        // A NEAR MISS must not open the gate: "delete" is not "DELETE", and a
        // regression that merely checked for non-empty text would pass without
        // this. (Lowercase also pins the comparison as case-SENSITIVE.)
        field.click()
        field.typeText("delete")
        XCTAssertFalse(deleteEverything.isEnabled,
                       "Delete Everything must stay DISABLED for a near-miss ('delete')")

        field.typeKey("a", modifierFlags: .command)
        field.typeText("DELETE")

        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"),
                                  evaluatedWith: deleteEverything)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed,
                       "Delete Everything must become ENABLED once the field reads DELETE")

        // Never actually delete: back out at the last gate.
        confirm.buttons["Cancel"].click()
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 10),
                      "cancelling should return to the Data pane")
        XCTAssertEqual(app.state, .runningForeground, "the app should still be running")

        // REOPENING must not find the gate pre-authorized. A spent "DELETE" left
        // in the field would mean the next trip through this flow arrives with
        // the destructive button already enabled — one tap from a wipe.
        scrollIntoView(deleteAll, in: settingsWindow(app))
        deleteAll.click()
        let scopeAgain = modal(app, containing: "Delete Data Only")
        XCTAssertTrue(scopeAgain.waitForExistence(timeout: 15),
                      "the scope alert should appear again")
        scopeAgain.buttons["Delete Data Only"].click()

        let confirmAgain = modal(app, containing: "Delete Everything")
        XCTAssertTrue(confirmAgain.waitForExistence(timeout: 15),
                      "the type-to-confirm alert should appear again")
        let fieldAgain = confirmField(in: confirmAgain)
        XCTAssertTrue(fieldAgain.waitForExistence(timeout: 15))
        XCTAssertEqual(fieldAgain.value as? String ?? "", "",
                       "the confirmation field must be EMPTY on re-entry, not still reading DELETE")
        XCTAssertFalse(confirmAgain.buttons["Delete Everything"].isEnabled,
                       "Delete Everything must be DISABLED again on re-entry")
        confirmAgain.buttons["Cancel"].click()

        // Prove the cancel actually held: close Settings and re-read the count.
        settingsWindow(app).typeKey("w", modifierFlags: .command)
        XCTAssertTrue(countLabel.waitForExistence(timeout: 15),
                      "the dashboard should be back after closing Settings")
        XCTAssertEqual(reportCount(countText(countLabel)), reportsBefore,
                       "cancelling at the typed-DELETE gate must leave every report intact")
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

    /// The alert surface hosting a button named `label` — a SwiftUI `.alert` lands
    /// as a sheet on macOS, but has also come through as a dialog/alert.
    ///
    /// POLLS to a deadline instead of probing once. Callers reach here immediately
    /// after the click that raises the alert, so a single pass would evaluate every
    /// surface before any of them exist and then pick one by coin-flip — the same
    /// TOCTOU shape this repo removed from the iOS helpers. Return only a surface
    /// we have SEEN hosting the button; if none ever appears, hand back a query for
    /// the button itself so the caller's `waitForExistence` fails on the thing it
    /// actually cares about rather than on an arbitrary empty surface.
    @MainActor
    private func modal(_ app: XCUIApplication, containing label: String,
                       timeout: TimeInterval = 15) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for surface in [app.sheets, app.dialogs, app.alerts] {
                let match = surface.containing(.button, identifier: label).firstMatch
                if match.exists { return match }
            }
            usleep(100_000)
        } while Date() < deadline
        return app.descendants(matching: .any).matching(identifier: label).firstMatch
    }

    /// Scrolls `element` into view if it exists but isn't hittable. macOS XCUI
    /// won't do this for you — `.click()` on an off-screen element fails outright
    /// ("Not hittable"), which is how the Danger Zone button failed on CI's
    /// shorter display while passing on a tall one. Tries downward first (the
    /// common case: the target is below the fold), then upward.
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, in window: XCUIElement,
                                steps: Int = 10) {
        guard element.exists, !element.isHittable else { return }
        let scroller = window.scrollViews.firstMatch.exists
            ? window.scrollViews.firstMatch : window
        for delta in [-120.0, 120.0] {
            for _ in 0..<steps {
                guard !element.isHittable else { return }
                scroller.scroll(byDeltaX: 0, deltaY: CGFloat(delta))
            }
        }
    }

    /// On macOS a SwiftUI `Text` exposes its content as the accessibility *value*
    /// (AppKit), where iOS exposes it as the label — read value first, fall back.
    @MainActor
    private func countText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Parses the leading integer out of a "N reports" string.
    private func reportCount(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    @MainActor
    private func confirmField(in modal: XCUIElement) -> XCUIElement {
        let byIdentifier = modal.textFields["delete-confirm-field"]
        if byIdentifier.exists { return byIdentifier }
        return modal.textFields.firstMatch
    }
}
