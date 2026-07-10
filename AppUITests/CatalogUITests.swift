import XCTest

final class CatalogUITests: XCTestCase {
    /// Catalog opens from Settings → Questions, renders the STUBBED provider's
    /// entries (never real CloudKit under --ui-testing), and "Add to my
    /// questions" creates an ordinary local Question that appears in the
    /// Questions list.
    @MainActor
    func testCatalogBrowsesStubbedEntriesAndAddCreatesLocalQuestion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Home → Settings → Questions.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        // Questions → Question Catalog.
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        // Stubbed entries render.
        let stubEntry = app.staticTexts["DID YOU DRINK WATER TODAY?"]
        XCTAssertTrue(stubEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["HOW IS YOUR ENERGY LEVEL?"].exists)

        // Open the entry and add it to my questions.
        stubEntry.tap()
        let addButton = app.buttons["catalog-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()

        let status = app.staticTexts["catalog-detail-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Added to your questions.")

        // Back to catalog, back to Questions: the new local question exists.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let newQuestionRow = app.staticTexts["DID YOU DRINK WATER TODAY?"]
        XCTAssertTrue(newQuestionRow.waitForExistence(timeout: 10),
                      "expected the added catalog question to appear in the local Questions list")
    }

    /// The question editor exposes a "Submit to Catalog" button, disabled
    /// while the draft can't pass catalog validation (here: an empty prompt on
    /// a brand-new question).
    @MainActor
    func testEditorSubmitToCatalogButtonGatedOnValidity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        let addButton = app.buttons["add-question-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()

        // The button lives at the bottom of the form — scroll to it.
        let submit = app.buttons["submit-to-catalog"]
        var scrolls = 6
        while !submit.exists, scrolls > 0 { app.swipeUp(); scrolls -= 1 }
        XCTAssertTrue(submit.exists, "expected a Submit to Catalog button in the editor")
        XCTAssertFalse(submit.isEnabled, "empty prompt should disable catalog submission")
    }
}
