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
/// Screenshots refresh: every shot launches the app fresh with a DIFFERENT
/// theme (`--theme <name>`, test-gated in DispatchApp) cycling through the
/// full palette — the original Reporter App Store listing look. The shot →
/// theme assignment is a deterministic modulo over `themes`, so re-runs are
/// pixel-identical.
///
/// Not capturable this way (documented limitation): the home/lock-screen
/// widget gallery and Control Center — XCUITest cannot drive springboard's
/// widget-add sheet for another app. Those shots, if wanted, are manual.
final class ScreenshotTests: XCTestCase {
    /// Matches Theme.allCases order in DispatchKit (tomato is the default,
    /// so the hero shot keeps the app's stock look).
    private static let themes = ["tomato", "teal", "gray", "pink", "chartreuse"]

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1",
            "screenshot capture runs only via scripts/screenshots.sh"
        )
        continueAfterFailure = false
    }

    /// Fresh launch for shot number `shotIndex` (1-based): deterministic
    /// demo fixture + the shot's cycled theme.
    ///
    /// Review-pass hardening: a springboard permission alert is dismissed if
    /// present (one leaked into a captured hero shot), and the applied theme
    /// is VERIFIED via the app's test-only `active-theme` AX marker — one
    /// wrong-theme shot slipped through when a relaunch didn't take the
    /// launch argument; a mismatch now relaunches once and then fails loudly.
    @MainActor
    private func launchApp(shotIndex: Int) -> XCUIApplication {
        let themeName = Self.themes[(shotIndex - 1) % Self.themes.count]
        var app = XCUIApplication()
        for attempt in 0..<2 {
            app = XCUIApplication()
            app.launchArguments = [
                "--mock-sensors", "--ui-testing", "--skip-onboarding", "--demo-data",
                "--theme", themeName,
            ]
            app.launch()
            dismissSystemPermissionAlertIfPresent()
            let marker = app.staticTexts["active-theme"]
            if marker.waitForExistence(timeout: 15), marker.label == themeName {
                return app
            }
            XCTAssertTrue(attempt == 0, "theme \(themeName) did not apply after relaunch "
                + "(marker: \(marker.exists ? marker.label : "missing"))")
            app.terminate()
        }
        return app
    }

    /// Any springboard-level permission dialog (e.g. notifications) blocks
    /// dead-center over the app. Allow is tapped so the grant persists and
    /// the dialog can't reappear later in the run.
    @MainActor
    private func dismissSystemPermissionAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The survey checklist's sensor rows show "GETTING …" while the (mock)
    /// providers resolve; a mid-collection capture photographs as broken.
    /// Mock sensors settle deterministically — wait them out.
    @MainActor
    private func awaitSensorRowsSettled(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let gettingRows = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'GETTING'"))
        let deadline = Date().addingTimeInterval(timeout)
        while gettingRows.count > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(gettingRows.count, 0, "sensor rows still collecting after \(Int(timeout))s")
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

    /// Waits for the home screen to be interactive after a fresh launch.
    @MainActor
    private func awaitHome(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["report-count"].waitForExistence(timeout: 15))
    }

    /// Navigates home → Settings root.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 15))
        app.buttons["settings-button"].tap()
    }

    /// One deterministic pass over the money shots. A single ordered method
    /// (not one test per screen) so the numbering is stable; each shot boots
    /// the app fresh because the theme is a launch argument.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        // 01 — home visualization (proportion bands over the demo data).
        var app = launchApp(shotIndex: 1)
        awaitHome(app)
        // Let the paged viz settle (charts animate in).
        Thread.sleep(forTimeInterval: 2)
        snap("01-home-viz")
        app.terminate()

        // 02 — report detail.
        app = launchApp(shotIndex: 2)
        awaitHome(app)
        app.buttons["reports-list-button"].tap()
        let firstRow = app.descendants(matching: .any).matching(identifier: "report-row").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()
        Thread.sleep(forTimeInterval: 1)
        snap("02-report-detail")
        app.terminate()

        // 03 — survey: checklist + first question.
        app = launchApp(shotIndex: 3)
        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 15))
        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))
        awaitSensorRowsSettled(app)
        Thread.sleep(forTimeInterval: 1)
        snap("03-survey-checklist")
        app.terminate()

        // 04 — prompt groups list.
        app = launchApp(shotIndex: 4)
        openSettings(app)
        let groupsLink = app.buttons["prompt-groups-link"]
        XCTAssertTrue(groupsLink.waitForExistence(timeout: 10))
        groupsLink.tap()
        // Rows render group names uppercased.
        var workdayRow = app.staticTexts["WORKDAY CHECK-IN"]
        XCTAssertTrue(workdayRow.waitForExistence(timeout: 10))
        snap("04-prompt-groups")
        app.terminate()

        // 05 — prompt group editor.
        app = launchApp(shotIndex: 5)
        openSettings(app)
        XCTAssertTrue(app.buttons["prompt-groups-link"].waitForExistence(timeout: 10))
        app.buttons["prompt-groups-link"].tap()
        workdayRow = app.staticTexts["WORKDAY CHECK-IN"]
        XCTAssertTrue(workdayRow.waitForExistence(timeout: 10))
        workdayRow.tap()
        XCTAssertTrue(app.textFields["group-name"].waitForExistence(timeout: 10))
        snap("05-prompt-group-editor")
        app.terminate()

        // 06 — weekly digest (template path renders deterministically under
        // --mock-sensors; demo data fills the stats + narrative).
        app = launchApp(shotIndex: 6)
        openSettings(app)
        let digestLink = app.buttons["weekly-digest-link"]
        XCTAssertTrue(digestLink.waitForExistence(timeout: 10))
        digestLink.tap()
        XCTAssertTrue(app.staticTexts["digest-narrative"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("06-weekly-digest")
        app.terminate()

        // 07 — insights over the demo data (bonus).
        app = launchApp(shotIndex: 7)
        openSettings(app)
        let insightsLink = app.buttons["insights-link"]
        XCTAssertTrue(insightsLink.waitForExistence(timeout: 10))
        insightsLink.tap()
        XCTAssertTrue(app.otherElements["insights-view"].waitForExistence(timeout: 15)
                      || app.collectionViews["insights-view"].waitForExistence(timeout: 15)
                      || app.scrollViews["insights-view"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("07-insights")
        app.terminate()

        // 08 — data settings: export/import/backups/delete-all (bonus).
        app = launchApp(shotIndex: 8)
        openSettings(app)
        let dataLink = app.buttons["data-settings-link"]
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()
        XCTAssertTrue(app.buttons["backup-now"].waitForExistence(timeout: 10)
                      || app.switches["backup-enabled"].waitForExistence(timeout: 10))
        snap("08-backups")
        app.terminate()
    }
}
