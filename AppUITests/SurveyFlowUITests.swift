import XCTest

final class SurveyFlowUITests: XCTestCase {
    /// Launches the app and opens the survey; returns the page counter
    /// element ("1 / 7") once the first page is up.
    @MainActor
    private func openSurvey(_ app: XCUIApplication) -> XCUIElement {
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["report-count"].waitForExistence(timeout: 10))
        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let counter = app.staticTexts["survey-page-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        return counter
    }

    /// Waits for the "N / M" page counter to reach `page`.
    @MainActor
    private func waitForPage(_ page: Int, counter: XCUIElement,
                             _ message: String, file: StaticString = #filePath,
                             line: UInt = #line) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "\(page) /")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: counter)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "\(message) (counter shows '\(counter.label)')", file: file, line: line)
    }

    /// Yes/No auto-advance (Reporter parity): tapping Yes must record the
    /// answer and move to the next page on its own — no NEXT tap.
    @MainActor
    func testYesNoTapAutoAdvances() throws {
        let app = XCUIApplication()
        let counter = openSurvey(app)
        XCTAssertTrue(counter.label.hasPrefix("1 /"), "survey did not start on page 1")

        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 10), "first page is not the yes/no question")
        yes.tap()

        // Deliberately no survey-next tap here.
        waitForPage(2, counter: counter, "tapping Yes did not auto-advance")
    }

    /// Swiping left-to-right goes back to the previous question, and the
    /// answer given before leaving it is still selected.
    @MainActor
    func testSwipeBackShowsPreviousQuestionWithPreservedAnswer() throws {
        let app = XCUIApplication()
        let counter = openSurvey(app)

        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        yes.tap()
        waitForPage(2, counter: counter, "tapping Yes did not auto-advance")

        app.swipeRight()
        waitForPage(1, counter: counter, "back swipe did not return to page 1")

        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        XCTAssertTrue(yes.isSelected, "Yes answer was not preserved after swiping back")
    }

    /// Forward swipe has NEXT-button semantics: both advance from the same
    /// page to the same next page (NEXT is ungated, so the swipe is too).
    @MainActor
    func testSwipeForwardMatchesNextButton() throws {
        let app = XCUIApplication()
        let counter = openSurvey(app)

        // Forward swipe with no answer given — exactly what NEXT allows.
        app.swipeLeft()
        waitForPage(2, counter: counter, "forward swipe did not advance")

        // Round-trip: back swipe, then NEXT reaches the same page the swipe did.
        app.swipeRight()
        waitForPage(1, counter: counter, "back swipe did not return to page 1")
        app.buttons["survey-next"].tap()
        waitForPage(2, counter: counter, "NEXT did not land on the same page as the forward swipe")
    }

    @MainActor
    func testCompleteReportFlowSavesReport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label // e.g. "0 reports"

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        // Answer whatever the first page offers if it's a choice list; then
        // press NEXT until DONE appears, then DONE.
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before)
    }

    /// Regression test for the keyboard-freeze bug: typing into the note
    /// question was causing every survey page to rebuild on each keystroke
    /// (the whole @Observable `answers` dict is one tracked property, so any
    /// mutation invalidated `SurveyFlowView.body` and rebuilt the entire
    /// TabView/ForEach). Types a long string into the note editor and asserts
    /// it completes within a sane bound.
    @MainActor
    func testTypingPerformance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        // Navigate to the note question ("What did you learn today?"),
        // seeded last by seedDefaultQuestionsIfNeeded().
        let noteEditor = app.textViews["note-editor"]
        while !noteEditor.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 10))
        noteEditor.tap()

        let longString = String(repeating: "the quick brown fox jumps over ", count: 6) // 192 chars
        XCTAssertGreaterThan(longString.count, 150)

        let start = Date()
        noteEditor.typeText(longString)
        let elapsed = Date().timeIntervalSince(start)

        print("TYPING-ELAPSED: \(elapsed)")
        XCTAssertEqual(noteEditor.value as? String, longString)
        // Generous bound: healthy typing of ~190 chars should stay well
        // under this. The freeze made this take tens of seconds.
        XCTAssertLessThan(elapsed, 10, "typing took \(elapsed)s — keyboard freeze regression")
    }

    /// Regression test for the flush contract: propagation of local keystroke
    /// state into the survey model is debounced (~300ms idle), so tapping
    /// DONE immediately after typing — with no idle wait — must force an
    /// immediate flush. Otherwise the last keystrokes would never make it
    /// into the saved report. Types into the note field, taps DONE with no
    /// delay, then verifies both that the report count incremented and that
    /// the exact typed text is present in the persisted report's detail view.
    @MainActor
    func testImmediateDoneAfterTypingFlushesPendingText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        let noteEditor = app.textViews["note-editor"]
        while !noteEditor.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 10))
        noteEditor.tap()

        let flushProbeText = "flush-probe-\(Int(Date().timeIntervalSince1970))"
        noteEditor.typeText(flushProbeText)

        // No idle wait here — this is the whole point of the test: DONE must
        // beat the 300ms debounce timer and still capture the typed text.
        XCTAssertEqual(next.label, "DONE", "note question should be the last page")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before, "report count did not increment")

        // Open the freshly saved report and assert the exact typed text
        // persisted — a real assertion on content, not just the count.
        app.buttons["reports-list-button"].tap()
        let reportsList = app.collectionViews["reports-list"].exists
            ? app.collectionViews["reports-list"]
            : app.tables["reports-list"]
        XCTAssertTrue(reportsList.waitForExistence(timeout: 10))
        let firstRow = app.buttons["report-row"].firstMatch.exists
            ? app.buttons["report-row"].firstMatch
            : app.cells["report-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        let savedText = app.staticTexts[flushProbeText]
        XCTAssertTrue(savedText.waitForExistence(timeout: 10),
                       "typed text '\(flushProbeText)' was not found in the saved report — debounced flush was lost")
    }

    /// Regression test for issue #1: text typed into a token/people field
    /// only tokenized on Return (`onSubmit`), so tapping NEXT/DONE (or
    /// swiping) without pressing Return silently dropped the entry and the
    /// report saved an empty token answer. Types into the tokens question
    /// WITHOUT pressing Return, advances with NEXT/DONE, then asserts the
    /// token is present in the persisted report's detail view.
    @MainActor
    func testAdvancingWithoutReturnTokenizesPendingTokenText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        // Navigate to the tokens question ("What are you doing?").
        let tokenField = app.textFields["token-field"]
        while !tokenField.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        tokenField.tap()

        let tokenText = "tokenprobe\(Int(Date().timeIntervalSince1970))"
        tokenField.typeText(tokenText)

        // Deliberately NO Return here — advancing must tokenize the draft.
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before, "report count did not increment")

        // Open the freshly saved report and assert the token persisted.
        app.buttons["reports-list-button"].tap()
        let reportsList = app.collectionViews["reports-list"].exists
            ? app.collectionViews["reports-list"]
            : app.tables["reports-list"]
        XCTAssertTrue(reportsList.waitForExistence(timeout: 10))
        let firstRow = app.buttons["report-row"].firstMatch.exists
            ? app.buttons["report-row"].firstMatch
            : app.cells["report-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        let savedToken = app.staticTexts[tokenText]
        XCTAssertTrue(savedToken.waitForExistence(timeout: 10),
                      "token '\(tokenText)' was not found in the saved report — draft was dropped by NEXT/DONE")
    }

    /// Plan 21 (number input styles): create a number question, switch its
    /// input style to Slider in the editor, run a survey, move the slider,
    /// and assert the numeric answer lands in the saved report's detail —
    /// proving the custom control writes through the same numericResponse
    /// path as the text field.
    @MainActor
    func testNumberQuestionSliderStyleSavesAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Settings → Questions → ADD A QUESTION.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        let addButton = app.buttons["add-question-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        var scrollsRemaining = 8
        while !addButton.isHittable, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        addButton.tap()

        let promptField = app.textFields["Prompt"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()
        let questionPrompt = "Slider probe \(Int(Date().timeIntervalSince1970) % 100_000)"
        promptField.typeText(questionPrompt)

        // Form pickers render as a menu: Type → Number.
        let typePicker = app.buttons["question-type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 10))
        typePicker.tap()
        let numberOption = app.buttons["Number"]
        XCTAssertTrue(numberOption.waitForExistence(timeout: 10))
        numberOption.tap()

        // INPUT STYLE → Slider (defaults 0–10, step 1).
        let stylePicker = app.buttons["input-style"]
        XCTAssertTrue(stylePicker.waitForExistence(timeout: 10))
        stylePicker.tap()
        let sliderOption = app.buttons["Slider"]
        XCTAssertTrue(sliderOption.waitForExistence(timeout: 10))
        sliderOption.tap()

        app.buttons["Save"].tap()

        // Back out of Questions, then Settings, to Home.
        XCTAssertTrue(app.buttons["add-question-button"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Run a survey and drive the slider on the new question's page.
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        let slider = app.sliders["number-slider"]
        while !slider.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(slider.waitForExistence(timeout: 10),
                      "slider control never appeared — input style did not reach the survey")

        // Full right = the slider's max (10 with default config, step 1).
        slider.adjust(toNormalizedSliderPosition: 1.0)

        // The new question sorts last, so this should already be DONE.
        while next.label == "NEXT" { next.tap() }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before, "report count did not increment")

        // Open the saved report: the slider's answer must show as the
        // question's numeric response.
        app.buttons["reports-list-button"].tap()
        let reportsList = app.collectionViews["reports-list"].exists
            ? app.collectionViews["reports-list"]
            : app.tables["reports-list"]
        XCTAssertTrue(reportsList.waitForExistence(timeout: 10))
        let firstRow = app.buttons["report-row"].firstMatch.exists
            ? app.buttons["report-row"].firstMatch
            : app.cells["report-row"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        XCTAssertTrue(app.staticTexts[questionPrompt.uppercased()].waitForExistence(timeout: 10)
                      || app.staticTexts[questionPrompt].waitForExistence(timeout: 10),
                      "the slider question was not in the saved report detail")
        XCTAssertTrue(app.staticTexts["10"].waitForExistence(timeout: 10),
                      "slider answer '10' was not found in the saved report — numericResponse path broken")
    }
}
