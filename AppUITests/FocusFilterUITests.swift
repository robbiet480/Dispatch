import XCTest

final class FocusFilterUITests: XCTestCase {
    /// Plan 15: with a FocusFilterState injected through the test-only
    /// FOCUS_FILTER_STATE launch-environment hook (DispatchApp writes it
    /// into the isolated per-launch defaults suite), the notification
    /// settings screen shows the passive Focus-filter status row.
    /// Deterministic — no real Focus, no Settings app, no system state.
    @MainActor
    func testInjectedFocusFilterShowsStatusRowInNotificationSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launchEnvironment["FOCUS_FILTER_STATE"] = """
        {"label":"Work","allowedGroupIDs":["group-a","group-b"],"pauseGlobal":true,"activatedAt":772000000}
        """
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let notificationsLink = app.buttons["notifications-settings-link"]
        XCTAssertTrue(notificationsLink.waitForExistence(timeout: 10))
        notificationsLink.tap()

        // The status row surfaces the injected label + allowed group count,
        // and states that ungrouped prompts are paused (pauseGlobal: true).
        XCTAssertTrue(
            app.staticTexts["Focus filter: Work — 2 groups"].waitForExistence(timeout: 10),
            "expected the Focus filter status row for the injected state"
        )
        XCTAssertTrue(
            app.staticTexts["Only these prompt groups are firing; ungrouped prompts are paused."].exists
        )
    }
}
