import XCTest

/// Watch App Store screenshot capture — the wrist-sized sibling of
/// AppUITests/ScreenshotTests. Same contract: every test skips unless
/// SCREENSHOT_MODE=1 is in the runner environment (scripts/screenshots.sh
/// sets it via TEST_RUNNER_SCREENSHOT_MODE), so normal test runs pay only a
/// skip; scripts/screenshots.sh extracts the shot-* attachments from the
/// xcresult.
///
/// NO per-shot themes here: the watch app has no ThemeColor/ThemeStore
/// system (documented limitation) — watch shots use the stock look.
///
/// Fixture: the test-environment launch (`--ui-testing`/`--mock-sensors`)
/// seeds the deterministic default-question set into an in-memory store
/// (DispatchWatchApp seeds DefaultQuestions under test) — the watch UI's
/// whole surface is the question list + per-question answering, so no
/// report fixture is needed.
final class WatchScreenshotTests: XCTestCase {
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
        app.launchArguments = ["--mock-sensors", "--ui-testing"]
        app.launch()
        return app
    }

    /// Full-screen capture — same `shot-` prefix contract as the iOS suite.
    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "shot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureWatchScreenshots() throws {
        let app = launchApp()

        // 01 — home: quick answer front and center + the question list.
        XCTAssertTrue(app.buttons["watch-quick-answer-yes"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        snap("01-home")

        // 02 — answering a question (the multiple-choice sleep question is
        // the first row of the Questions section in default sortOrder).
        let sleepRow = app.staticTexts["How did you sleep?"]
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 10))
        sleepRow.tap()
        XCTAssertTrue(app.staticTexts["Answer"].waitForExistence(timeout: 10)
                      || app.navigationBars["Answer"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        snap("02-question-answer")

        // 03 — settings (sync toggle + about), via home.
        app.terminate()
        let relaunched = launchApp()
        let settingsLink = relaunched.buttons["watch-settings-link"]
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 15))
        // The link is the last list row — scroll it into view.
        relaunched.swipeUp()
        settingsLink.tap()
        Thread.sleep(forTimeInterval: 1)
        snap("03-settings")
    }
}
