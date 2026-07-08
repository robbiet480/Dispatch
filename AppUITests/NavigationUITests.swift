import XCTest

final class NavigationUITests: XCTestCase {
    @MainActor
    func testNavigationAndAwakeToggle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--skip-onboarding"]
        app.launch()

        // Reports list: open, assert, and navigate back.
        let reportsListButton = app.buttons["reports-list-button"]
        XCTAssertTrue(reportsListButton.waitForExistence(timeout: 10))
        reportsListButton.tap()

        XCTAssertTrue(
            app.otherElements["reports-list"].waitForExistence(timeout: 10)
                || app.collectionViews["reports-list"].waitForExistence(timeout: 10)
                || app.tables["reports-list"].waitForExistence(timeout: 10)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Settings -> Questions: open, assert, and navigate back out.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let questionsLink = app.staticTexts["Questions"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()

        XCTAssertTrue(
            app.otherElements["question-settings-list"].waitForExistence(timeout: 10)
                || app.collectionViews["question-settings-list"].waitForExistence(timeout: 10)
                || app.tables["question-settings-list"].waitForExistence(timeout: 10)
        )

        // Back out of Questions, then back out of Settings to Home.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Awake toggle: capture current state, tap it, expect the survey sheet, cancel it.
        let awakeToggle = app.buttons["awake-toggle"]
        XCTAssertTrue(awakeToggle.waitForExistence(timeout: 10))
        let beforeLabel = awakeToggle.label
        XCTAssertTrue(beforeLabel == "AWAKE" || beforeLabel == "ASLEEP")

        awakeToggle.tap()

        let surveyCancel = app.buttons["survey-cancel"]
        XCTAssertTrue(surveyCancel.waitForExistence(timeout: 10))
        surveyCancel.tap()

        // Toggling is authoritative even though the follow-up survey was cancelled,
        // so the label should have flipped between AWAKE and ASLEEP.
        XCTAssertTrue(awakeToggle.waitForExistence(timeout: 10))
        XCTAssertNotEqual(awakeToggle.label, beforeLabel)
    }
}
