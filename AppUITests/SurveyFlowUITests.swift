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

    /// Keyboard timing + persistence: a token/people page must bring the
    /// keyboard up on its own — focus is requested on page arrival, not on
    /// a field tap — and advancing from one text-entry question to the next
    /// (tokens → location here) must keep the keyboard up: focus hands off
    /// across the page transition instead of resigning into a dismiss/
    /// re-present bounce.
    @MainActor
    func testKeyboardAutoAppearsOnTokenPageAndPersistsAcrossTextPages() throws {
        let app = XCUIApplication()
        _ = openSurvey(app)

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))

        // Navigate to the tokens question ("What are you doing?").
        let tokenField = app.textFields["token-field"]
        while !tokenField.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))

        // Deliberately NO tap on the field: arriving on the page alone must
        // summon the keyboard, within a tight bound.
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3),
                      "keyboard did not auto-appear on the token page")

        // Tokens → location is text-entry → text-entry: the keyboard must
        // survive the programmatic advance.
        next.tap()
        XCTAssertTrue(app.textFields["location-field"].waitForExistence(timeout: 5),
                      "location question did not follow the tokens question")
        XCTAssertTrue(app.keyboards.element.exists,
                      "keyboard dismissed while advancing between text questions")
    }

    /// Creates a time question via the editor (Type → Time), then adds it, and
    /// returns the app on the Questions screen. Shared by the two time flows.
    @MainActor
    private func addTimeQuestion(_ app: XCUIApplication, prompt: String) {
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
        promptField.typeText(prompt)

        let typePicker = app.buttons["question-type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 10))
        typePicker.tap()
        let timeOption = app.buttons["Time"]
        XCTAssertTrue(timeOption.waitForExistence(timeout: 10))
        timeOption.tap()

        app.buttons["Save"].tap()

        // Back out of Questions, then Settings, to Home.
        XCTAssertTrue(app.buttons["add-question-button"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Plan 28 (time question), both branches in one launch: add TWO time
    /// questions, run a single survey, drive Now → Yesterday on the first and
    /// leave the second untouched, then assert the saved report BOTH shows a
    /// "(yesterday)"-tagged time answer (touched → the wheel/Now/Yesterday
    /// controls write `.time` through the shared answer path) AND omits the
    /// untouched question's row (untouched == skipped, the number-control
    /// convention). The untouched==nil semantics are pinned by TimeAnswerTests
    /// (kit); this UI test covers the survey/editor plumbing for both branches.
    @MainActor
    func testTimeQuestionTouchedSavesAndUntouchedRecordsNoAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Added questions sort last, in insertion order, so the touched one
        // (added first) precedes the untouched one in the survey.
        let touchedPrompt = "Ate probe \(Int(Date().timeIntervalSince1970) % 100_000)"
        addTimeQuestion(app, prompt: touchedPrompt)
        let untouchedPrompt = "Skipped time \(Int(Date().timeIntervalSince1970) % 100_000)"
        addTimeQuestion(app, prompt: untouchedPrompt)

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }

        // First time question: drive Now → Yesterday (the touched path).
        let nowButton = app.buttons["time-now"]
        while !nowButton.exists && next.label == "NEXT" {
            next.tap()
        }
        XCTAssertTrue(nowButton.waitForExistence(timeout: 10),
                      "time input never appeared — the .time case did not reach the survey")
        nowButton.tap()
        app.buttons["time-yesterday"].tap()

        // Advance through the remaining pages — including the SECOND time
        // question — without touching them, leaving it untouched (skipped).
        while next.label == "NEXT" { next.tap() }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before, "report count did not increment")

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

        // Touched path: a time answer tagged "(yesterday)" is present.
        let yesterdayText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "(yesterday)")).firstMatch
        XCTAssertTrue(yesterdayText.waitForExistence(timeout: 10),
                      "no time answer tagged '(yesterday)' in the saved report — .time path broken")

        // Untouched path: the untouched time question shows no answer row
        // (answerText == nil), so its uppercased prompt never appears in the
        // detail list.
        XCTAssertFalse(app.staticTexts[untouchedPrompt.uppercased()].exists,
                       "untouched time question was recorded as answered")
    }
}
