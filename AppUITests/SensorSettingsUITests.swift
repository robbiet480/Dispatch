import XCTest

/// Sensor permission affordances (per-row status + bottom "Request All").
/// Real framework statuses can't be driven from UI tests, so these use the
/// test-environment stub: `SENSOR_PERMISSION_STATUSES` launch-environment
/// JSON feeds SensorPermissionStatusProvider per-permission states.
final class SensorSettingsUITests: XCTestCase {
    @MainActor
    private func launchToSensors(statuses: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors", "--skip-onboarding"]
        if let statuses {
            app.launchEnvironment["SENSOR_PERMISSION_STATUSES"] = statuses
        }
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        let sensorsLink = app.buttons["Sensors"].firstMatch
        XCTAssertTrue(sensorsLink.waitForExistence(timeout: 10))
        sensorsLink.tap()
        return app
    }

    @MainActor
    func testPermissionAffordancesRenderStubbedStates() throws {
        let app = launchToSensors(
            statuses: #"{"location":"granted","microphone":"notDetermined","photos":"denied"}"#
        )

        // Not-determined renders a "Request" button beside a locked slider.
        let request = app.buttons["permission-request-microphone"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertEqual(request.label, "Request")

        // Denied renders a "Settings" button (deep link) beside a locked slider.
        let settings = app.buttons["permission-settings-photos"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertEqual(settings.label, "Settings")

        // Granted leaves the slider free — no Request/Settings button on the
        // location rows (Location/Weather/Elevation share the permission).
        XCTAssertFalse(app.buttons["permission-request-location"].exists)
        XCTAssertFalse(app.buttons["permission-settings-location"].exists)

        // Something is requestable, so the bulk request row is present —
        // scroll to it (List rows materialize lazily; the bottom of the
        // SENSORS section starts off screen).
        let requestAll = app.buttons["request-all-sensors"]
        var scrollsRemaining = 6
        while !requestAll.exists, scrollsRemaining > 0 {
            app.swipeUp()
            scrollsRemaining -= 1
        }
        XCTAssertTrue(requestAll.exists)
    }

    @MainActor
    func testRequestAllHiddenWhenNothingRequestable() throws {
        let app = launchToSensors(
            statuses: #"{"location":"granted","health":"requested","motion":"granted","microphone":"denied","photos":"denied","mediaLibrary":"granted","focus":"granted"}"#
        )

        // Screen is up (the location sensor row is visible)…
        XCTAssertTrue(app.switches["sensor-toggle-location"].firstMatch.waitForExistence(timeout: 10))
        // …but with nothing in not-determined there is nothing to request:
        // scroll through the whole section (rows are lazy) and confirm the
        // bulk row never materializes.
        for _ in 0..<6 where !app.buttons["request-all-sensors"].exists {
            app.swipeUp()
        }
        XCTAssertFalse(app.buttons["request-all-sensors"].exists)
    }
}
