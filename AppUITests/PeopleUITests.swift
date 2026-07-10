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
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        let sensorsLink = app.buttons["Sensors"].firstMatch.exists
            ? app.buttons["Sensors"].firstMatch
            : app.staticTexts["Sensors"].firstMatch
        XCTAssertTrue(sensorsLink.waitForExistence(timeout: 10))
        sensorsLink.tap()
        let toggle = app.switches["contacts-suggestions-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        var scrollsRemaining = 6
        while !toggle.isHittable, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        toggle.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Start a report and navigate to the people question.
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
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
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
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
        app.buttons["settings-button"].tap()
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
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Renamedprobe"].waitForExistence(timeout: 10),
                      "renamed person did not appear in the People list")
        XCTAssertTrue(app.staticTexts["Also: Personprobe"].waitForExistence(timeout: 10),
                      "old name did not surface as an alternate name")
    }
}
