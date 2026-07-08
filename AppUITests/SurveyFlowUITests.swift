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
}
