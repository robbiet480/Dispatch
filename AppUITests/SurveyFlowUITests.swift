import XCTest

final class SurveyFlowUITests: XCTestCase {
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
}
