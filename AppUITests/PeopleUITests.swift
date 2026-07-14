import XCTest

/// Plan 22: person identity + Contacts integration. Runs entirely against
/// the stub contact provider (--ui-testing/--mock-sensors) — no permission
/// dialogs, deterministic "Stub …" fixtures.
final class PeopleUITests: XCTestCase {
    /// Enables "Suggest from Contacts" in Settings → Sensors, then types a
    /// prefix into the people question and asserts blended suggestions
    /// render: stub contact chips appear alongside history behavior, and
    /// picking one adds the display name as a token chip.
    @MainActor
    func testStubBlendedContactSuggestionsRenderAndPick() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Settings → Sensors → toggle contacts suggestions ON.
        app.openSettings()
        let sensorsLink = app.buttons["Sensors"].firstMatch.exists
            ? app.buttons["Sensors"].firstMatch
            : app.staticTexts["Sensors"].firstMatch
        XCTAssertTrue(sensorsLink.waitForExistence(timeout: 10))
        sensorsLink.tap()
        // The CONTACTS section sits below the fold of the sensors list, and
        // SwiftUI's lazy List doesn't REALIZE off-screen rows at all — the
        // toggle (and its identifier) doesn't exist in the accessibility
        // tree until scrolled into view, so scroll-until-exists, don't
        // wait-then-scroll.
        let toggle = app.switches["contacts-suggestions-toggle"].firstMatch
        var scrollsRemaining = 8
        while !toggle.exists, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "contacts toggle never appeared after scrolling the sensors list")
        // SwiftUI exposes the whole Toggle ROW as the switch element, so a
        // plain tap() lands at row center and does NOT flip it — tap the
        // trailing edge where the actual switch knob sits, then verify.
        toggle.tap()
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1",
                       "contacts suggestions toggle did not switch on")
        // Back to the dashboard. iPhone pops Sensors → Settings → Home; the iPad
        // shell dismisses the Settings sheet (Sensors is pushed inside it).
        if app.isPadShell {
            app.closeSettings()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Start a report and navigate to the people question.
        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 10))
        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        let peoplePrompt = app.staticTexts["WHO ARE YOU WITH?"]
        while !peoplePrompt.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(peoplePrompt.waitForExistence(timeout: 10),
                      "people question page never appeared")

        let tokenField = app.textFields["token-field"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        tokenField.tap()
        tokenField.typeText("Stub")

        // Blended suggestions: both stub contact fixtures prefix-match "Stub".
        let contactChip = app.buttons["token-suggestion-Stub Contact"]
        XCTAssertTrue(contactChip.waitForExistence(timeout: 10),
                      "stub contact suggestion did not render in the blended typeahead")
        XCTAssertTrue(app.buttons["token-suggestion-Stub Companion"].exists)

        // Picking a contact inserts the display name as a chip.
        contactChip.tap()
        XCTAssertTrue(app.staticTexts["Stub Contact"].waitForExistence(timeout: 10),
                      "picking the contact suggestion did not add its display name")
    }

    /// Task 3: the People management screen renders persons seeded through a
    /// filed report, and the rename flow (heals: old name → alternate names)
    /// updates the list.
    @MainActor
    func testPeopleScreenRendersAndRenameFlowUpdatesList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Seed a person by filing a report with a people answer.
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 10))
        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        let peoplePrompt = app.staticTexts["WHO ARE YOU WITH?"]
        while !peoplePrompt.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(peoplePrompt.waitForExistence(timeout: 10))
        let tokenField = app.textFields["token-field"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        tokenField.tap()
        tokenField.typeText("Personprobe\n")
        for _ in 0..<12 where next.label == "NEXT" { next.tap() }
        XCTAssertEqual(next.label, "DONE")
        next.tap()
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))

        // Settings → People: the seeded person renders.
        app.openSettings()
        let peopleLink = app.buttons["people-settings-link"]
        XCTAssertTrue(peopleLink.waitForExistence(timeout: 10))
        peopleLink.tap()
        let list = app.collectionViews["people-list"].exists
            ? app.collectionViews["people-list"]
            : app.tables["people-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "people-list did not render")
        let personRow = app.staticTexts["Personprobe"]
        XCTAssertTrue(personRow.waitForExistence(timeout: 10),
                      "seeded person did not appear in the People list")

        // Rename flow: detail → clear field → new name → Rename → list updates.
        personRow.tap()
        let renameField = app.textFields["person-rename-field"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 10))
        renameField.tap()
        let currentValue = (renameField.value as? String) ?? ""
        renameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                    count: currentValue.count))
        renameField.typeText("Renamedprobe")
        let renameButton = app.buttons["person-rename"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 10))
        renameButton.tap()

        // Back to the list: new display name shown, old name in the caption.
        // Both People and its detail are pushes; on the iPad shell they're inside
        // the Settings sheet (whose back control carries the `BackButton` id),
        // where a bare boundBy:0 would hit the background shell nav bar instead.
        if app.isPadShell {
            app.buttons["BackButton"].firstMatch.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.staticTexts["Renamedprobe"].waitForExistence(timeout: 10),
                      "renamed person did not appear in the People list")
        XCTAssertTrue(app.staticTexts["Also: Personprobe"].waitForExistence(timeout: 10),
                      "old name did not surface as an alternate name")
    }
}
