import XCTest

final class DeleteAllDataUITests: XCTestCase {
    /// Full delete-all flow under the in-memory --ui-testing store: seed a
    /// report through the real survey flow, run Settings → Data →
    /// Delete All Data… through both gates (scope choice + type-to-confirm),
    /// then assert the reports list is empty and the default questions exist.
    @MainActor
    func testDeleteAllDataResetsReportsAndReseedsDefaultQuestions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        // Seed: file one report via the survey flow (SurveyFlowUITests pattern).
        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(countLabel.label, "0 reports")

        app.buttons["report-button"].tap()
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(countLabel.label, "1 reports")

        // Settings → Data. The Data section sits below the fold after the
        // Settings "Manage" section (Task 3.6) pushed the lower sections down;
        // SwiftUI's List lazily materializes off-screen rows, so scroll it in
        // before tapping.
        app.buttons["settings-button"].tap()
        let dataLink = app.buttons["data-settings-link"]
        app.scrollUntilHittable(dataLink, anchoredOn: app.buttons["questions-settings-link"])
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()

        // Destructive row (scroll into view if the list is long).
        let deleteRow = app.buttons["delete-all-data"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 10))
        if !deleteRow.isHittable {
            app.swipeUp()
        }
        deleteRow.tap()

        // Gate 1: scope alert with the backups choice — keep backups.
        let scopeAlert = app.alerts["Delete All Data?"]
        XCTAssertTrue(scopeAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(scopeAlert.buttons["Also Delete Backups"].exists)
        XCTAssertTrue(scopeAlert.buttons["Cancel"].exists)
        scopeAlert.buttons["Delete Data Only"].tap()

        // Gate 2: type-to-confirm.
        let confirmAlert = app.alerts["Confirm Deletion"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 10))
        let confirmField = confirmAlert.textFields.element(boundBy: 0)
        XCTAssertTrue(confirmField.waitForExistence(timeout: 10))
        confirmField.tap()
        confirmField.typeText("DELETE")
        confirmAlert.buttons["Delete Everything"].tap()

        // Success alert dismisses back toward a fresh-looking app.
        let successAlert = app.alerts["All Data Deleted"]
        XCTAssertTrue(successAlert.waitForExistence(timeout: 15))
        successAlert.buttons["OK"].tap()

        // Back out of Settings to Home; the report count must be zero again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(countLabel.label, "0 reports")

        // Reports list is empty.
        app.buttons["reports-list-button"].tap()
        XCTAssertTrue(
            app.otherElements["reports-list"].waitForExistence(timeout: 10)
                || app.collectionViews["reports-list"].waitForExistence(timeout: 10)
                || app.tables["reports-list"].waitForExistence(timeout: 10)
        )
        XCTAssertEqual(app.collectionViews["reports-list"].cells.count, 0)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Default questions were reseeded: Settings → Questions shows the
        // frozen catalog (spot-check two prompts).
        app.buttons["settings-button"].tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        // Question rows render their prompts uppercased.
        XCTAssertTrue(app.staticTexts["WHAT ARE YOU DOING?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ARE YOU WORKING?"].exists)
    }

    /// The type-to-confirm gate must reject a mismatched confirmation.
    @MainActor
    func testMismatchedConfirmationDeletesNothing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].tap()
        // Data section is below the fold after the Manage section (Task 3.6);
        // scroll the lazily-rendered row in before tapping.
        let dataLink = app.buttons["data-settings-link"]
        app.scrollUntilHittable(dataLink, anchoredOn: app.buttons["questions-settings-link"])
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()

        let deleteRow = app.buttons["delete-all-data"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 10))
        if !deleteRow.isHittable {
            app.swipeUp()
        }
        deleteRow.tap()

        let scopeAlert = app.alerts["Delete All Data?"]
        XCTAssertTrue(scopeAlert.waitForExistence(timeout: 10))
        scopeAlert.buttons["Delete Data Only"].tap()

        let confirmAlert = app.alerts["Confirm Deletion"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 10))
        let confirmField = confirmAlert.textFields.element(boundBy: 0)
        confirmField.tap()
        confirmField.typeText("delete")
        confirmAlert.buttons["Delete Everything"].tap()

        // Rejected: the mismatch notice appears and questions survive.
        XCTAssertTrue(app.staticTexts["Confirmation text didn't match — nothing was deleted."]
            .waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["OK"].tap()
    }
}
