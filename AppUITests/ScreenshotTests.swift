import XCTest

/// App Store screenshot capture (plan 23). NOT part of the regular suite:
/// every test skips unless SCREENSHOT_MODE=1 is in the runner environment
/// (scripts/screenshots.sh sets it via TEST_RUNNER_SCREENSHOT_MODE), so CI
/// and local `xcodebuild test` runs pay only a skip.
///
/// Captures full-screen XCTAttachments (.keepAlways) over the deterministic
/// `--demo-data` fixture; scripts/screenshots.sh extracts the PNGs from the
/// xcresult and names them `<device>-<nn>-<name>.png`.
///
/// Not capturable this way (documented limitation): the home/lock-screen
/// widget gallery and Control Center — XCUITest cannot drive springboard's
/// widget-add sheet for another app. Those shots, if wanted, are manual.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1",
            "screenshot capture runs only via scripts/screenshots.sh"
        )
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding", "--demo-data"]
        app.launch()
        return app
    }

    /// Full-screen capture — the extraction script keys on the `shot-` prefix
    /// to tell screenshots apart from any framework-generated attachments.
    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "shot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One deterministic pass over the money shots. A single ordered method
    /// (not one test per screen) so the run boots the app once per flow and
    /// the numbering is stable.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        var app = launchApp()

        // 01 — home visualization (proportion bands over the demo data).
        XCTAssertTrue(app.staticTexts["report-count"].waitForExistence(timeout: 15))
        // Let the paged viz settle (charts animate in).
        Thread.sleep(forTimeInterval: 2)
        snap("01-home-viz")

        // 02 — report detail.
        app.buttons["reports-list-button"].tap()
        let firstRow = app.descendants(matching: .any).matching(identifier: "report-row").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()
        Thread.sleep(forTimeInterval: 1)
        snap("02-report-detail")

        // 03 — survey: capture checklist + first question. Relaunch for a
        // clean navigation stack (cheaper than unwinding detail → list → home).
        app.terminate()
        app = launchApp()
        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 15))
        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        snap("03-survey-checklist")

        // Cancel out (discard) so Settings is reachable.
        app.buttons["survey-cancel"].tap()
        let discardAlert = app.alerts["Are you sure you want to discard this report?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 10))
        discardAlert.buttons["Discard"].tap()

        // 04/05 — prompt groups list + editor.
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 10))
        app.buttons["settings-button"].tap()
        let groupsLink = app.buttons["prompt-groups-link"]
        XCTAssertTrue(groupsLink.waitForExistence(timeout: 10))
        groupsLink.tap()
        // Rows render group names uppercased.
        let workdayRow = app.staticTexts["WORKDAY CHECK-IN"]
        XCTAssertTrue(workdayRow.waitForExistence(timeout: 10))
        snap("04-prompt-groups")
        workdayRow.tap()
        XCTAssertTrue(app.textFields["group-name"].waitForExistence(timeout: 10))
        snap("05-prompt-group-editor")
        // Editor is a sheet/push with a save button; back out without saving.
        if app.navigationBars.buttons["Cancel"].exists {
            app.navigationBars.buttons["Cancel"].tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap() // groups → settings

        // 06 — weekly digest (template path renders deterministically under
        // --mock-sensors; demo data fills the stats + narrative).
        let digestLink = app.buttons["weekly-digest-link"]
        XCTAssertTrue(digestLink.waitForExistence(timeout: 10))
        digestLink.tap()
        XCTAssertTrue(app.staticTexts["digest-narrative"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("06-weekly-digest")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 07 — insights over the demo data (bonus).
        let insightsLink = app.buttons["insights-link"]
        XCTAssertTrue(insightsLink.waitForExistence(timeout: 10))
        insightsLink.tap()
        XCTAssertTrue(app.otherElements["insights-view"].waitForExistence(timeout: 15)
                      || app.collectionViews["insights-view"].waitForExistence(timeout: 15)
                      || app.scrollViews["insights-view"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("07-insights")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 08 — data settings: export/import/backups/delete-all (bonus).
        let dataLink = app.buttons["data-settings-link"]
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()
        XCTAssertTrue(app.buttons["backup-now"].waitForExistence(timeout: 10)
                      || app.switches["backup-enabled"].waitForExistence(timeout: 10))
        snap("08-backups")
    }
}
