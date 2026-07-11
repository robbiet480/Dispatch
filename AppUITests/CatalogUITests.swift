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

    /// Plan 41: adding a catalog entry that carries an input configuration
    /// (the stubbed "How stressed are you?" scale question) creates a local
    /// Question with the style, bounds, default answer, and placeholder
    /// populated — visible when the editor opens it.
    @MainActor
    func testAddConfiguredCatalogEntryMapsInputConfigOntoLocalQuestion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        // Open the configured stub entry (may need a scroll on small screens).
        let configured = app.staticTexts["HOW STRESSED ARE YOU?"]
        var scrolls = 4
        while !configured.exists, scrolls > 0 { app.swipeUp(); scrolls -= 1 }
        XCTAssertTrue(configured.waitForExistence(timeout: 10))
        configured.tap()

        let addButton = app.buttons["catalog-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        let status = app.staticTexts["catalog-detail-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Added to your questions.")

        // Back to catalog, back to Questions, open the new question's editor.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let newRow = app.staticTexts["HOW STRESSED ARE YOU?"]
        XCTAssertTrue(newRow.waitForExistence(timeout: 10))
        newRow.tap()

        // The editor shows the carried configuration: scale style, 1–5
        // bounds, default 3, placeholder text.
        let stylePicker = app.buttons["input-style"]
        var editorScrolls = 4
        while !stylePicker.exists, editorScrolls > 0 { app.swipeUp(); editorScrolls -= 1 }
        XCTAssertTrue(stylePicker.waitForExistence(timeout: 10))
        XCTAssertTrue(stylePicker.label.contains("Rating Scale"),
                      "expected the scale style, got: \(stylePicker.label)")
        XCTAssertEqual(app.textFields["input-min"].value as? String, "1")
        XCTAssertEqual(app.textFields["input-max"].value as? String, "5")
        XCTAssertEqual(app.textFields["default-answer-field"].value as? String, "3")
        XCTAssertEqual(app.textFields["Placeholder"].value as? String, "1 to 5")
    }

    /// Plan 41: the submit form shows INPUT STYLE + DEFAULT ANSWER sections
    /// only for number questions, an unconditional PLACEHOLDER field, and a
    /// configured number submission reaches the confirmation screen.
    @MainActor
    func testSubmitFormCarriesInputConfigForNumberQuestions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        let submitButton = app.buttons["catalog-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.tap()

        let promptField = app.textFields["catalog-submit-prompt"]
            .exists ? app.textFields["catalog-submit-prompt"] : app.textViews["catalog-submit-prompt"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()
        promptField.typeText("How loud was it?")

        // Fresh install: the quota footer must not advertise itself (plan 38).
        XCTAssertFalse(app.staticTexts["catalog-submit-quota"].exists)

        // Default (yesNo): no input-style/default sections, placeholder shown.
        XCTAssertFalse(app.buttons["catalog-submit-input-style"].exists)
        XCTAssertFalse(app.textFields["catalog-submit-default-answer"].exists)
        XCTAssertTrue(app.textFields["catalog-submit-placeholder"].exists)

        // Switch to Number: the configuration sections appear.
        app.buttons["catalog-submit-type"].firstMatch.tap()
        let numberOption = app.buttons["Number"].firstMatch
        XCTAssertTrue(numberOption.waitForExistence(timeout: 10))
        numberOption.tap()

        let stylePicker = app.buttons["catalog-submit-input-style"]
        XCTAssertTrue(stylePicker.waitForExistence(timeout: 10))
        stylePicker.tap()
        let scaleOption = app.buttons["Rating Scale"].firstMatch
        XCTAssertTrue(scaleOption.waitForExistence(timeout: 10))
        scaleOption.tap()

        let minField = app.textFields["catalog-submit-input-min"]
        XCTAssertTrue(minField.waitForExistence(timeout: 10))
        minField.tap()
        minField.typeText("1")
        let maxField = app.textFields["catalog-submit-input-max"]
        maxField.tap()
        maxField.typeText("5")
        let defaultField = app.textFields["catalog-submit-default-answer"]
        defaultField.tap()
        defaultField.typeText("3")
        // The number-question sections push PLACEHOLDER down; with the keyboard
        // up it can sit below the fold (notably on the iPad sheet), where the
        // List hasn't realized its row yet — scroll it into view first.
        let placeholderField = app.textFields["catalog-submit-placeholder"]
        var placeholderScrolls = 6
        while !placeholderField.exists, placeholderScrolls > 0 { app.swipeUp(); placeholderScrolls -= 1 }
        placeholderField.tap()
        placeholderField.typeText("1 to 5")

        app.buttons["catalog-submit-send"].tap()
        let confirmation = app.otherElements["catalog-submit-confirmation"]
            .exists ? app.otherElements["catalog-submit-confirmation"] : app.staticTexts["Thanks!"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
    }

    /// Plan 38: with the per-device quota exhausted (seeded via the
    /// CATALOG_SEEDED_SUBMISSIONS launch hook — no five round-trips), the
    /// submit form shows the quota footer with a reset time and disables
    /// Send. A fresh install (every other test in this file: seed 0) shows
    /// no quota UI at all.
    @MainActor
    func testSubmitQuotaExhaustedShowsFooterAndDisablesSend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launchEnvironment["CATALOG_SEEDED_SUBMISSIONS"] = "5"
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        let submitButton = app.buttons["catalog-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.tap()

        let send = app.buttons["catalog-submit-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "an exhausted quota should disable Send")

        // The footer sits at the bottom of the form — scroll to it.
        let quota = app.staticTexts["catalog-submit-quota"]
        var scrolls = 6
        while !quota.exists, scrolls > 0 { app.swipeUp(); scrolls -= 1 }
        XCTAssertTrue(quota.waitForExistence(timeout: 10))
        XCTAssertTrue(quota.label.contains("Daily limit reached"),
                      "expected the reset-time footer, got: \(quota.label)")
    }

    /// Plan 42: submitting a prompt that duplicates a catalog entry (the
    /// stubbed "Did you drink water today?" — matched case/whitespace/
    /// punctuation-insensitively) blocks with an "already in the catalog"
    /// section whose Add to My Questions button creates the local question.
    @MainActor
    func testSubmitDuplicatePromptOffersAddInstead() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        let submitButton = app.buttons["catalog-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.tap()

        let promptField = app.textFields["catalog-submit-prompt"]
            .exists ? app.textFields["catalog-submit-prompt"] : app.textViews["catalog-submit-prompt"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()
        // Messy variant of the stub entry: normalization must still match.
        promptField.typeText("did you DRINK water today?!")

        app.buttons["catalog-submit-send"].tap()

        // No confirmation — the duplicate section appears instead.
        let duplicateNote = app.staticTexts["catalog-submit-duplicate"]
        XCTAssertTrue(duplicateNote.waitForExistence(timeout: 10))
        XCTAssertTrue(duplicateNote.label.contains("Did you drink water today?"),
                      "expected the existing entry's prompt, got: \(duplicateNote.label)")
        XCTAssertFalse(app.otherElements["catalog-submit-confirmation"].exists)
        XCTAssertFalse(app.staticTexts["Thanks!"].exists)

        let addInstead = app.buttons["catalog-submit-duplicate-add"]
        XCTAssertTrue(addInstead.exists)
        addInstead.tap()
        XCTAssertTrue(app.staticTexts["catalog-submit-duplicate-added"].waitForExistence(timeout: 10))

        // Dismiss the sheet, leave the catalog: the local question exists.
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let newRow = app.staticTexts["DID YOU DRINK WATER TODAY?"]
        XCTAssertTrue(newRow.waitForExistence(timeout: 10),
                      "expected the added duplicate to appear in the local Questions list")
    }

    /// Plan 42: resubmitting a prompt this device already submitted (same
    /// launch, stub provider) is refused with the already-submitted message.
    @MainActor
    func testResubmittingOwnPromptIsRefused() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        // Unique prompt per run: the fingerprint memory persists in
        // UserDefaults across launches on the same simulator.
        let prompt = "Did you water plant \(Int(Date().timeIntervalSince1970))?"

        func submitPrompt() {
            let submitButton = app.buttons["catalog-submit-button"]
            XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
            submitButton.tap()
            let promptField = app.textFields["catalog-submit-prompt"]
                .exists ? app.textFields["catalog-submit-prompt"] : app.textViews["catalog-submit-prompt"]
            XCTAssertTrue(promptField.waitForExistence(timeout: 10))
            promptField.tap()
            promptField.typeText(prompt)
            app.buttons["catalog-submit-send"].tap()
        }

        submitPrompt()
        let confirmation = app.otherElements["catalog-submit-confirmation"]
            .exists ? app.otherElements["catalog-submit-confirmation"] : app.staticTexts["Thanks!"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        submitPrompt()
        let error = app.staticTexts["catalog-submit-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("already submitted"),
                      "expected the already-submitted refusal, got: \(error.label)")
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
