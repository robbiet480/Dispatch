import XCTest

final class NotificationSettingsUITests: XCTestCase {
    /// Navigates to Settings → Notifications and returns the launched app.
    @MainActor
    private func launchToNotificationSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let notificationsLink = app.buttons["notifications-settings-link"]
        XCTAssertTrue(notificationsLink.waitForExistence(timeout: 10))
        notificationsLink.tap()
        return app
    }

    /// Regression test: the Alerts per Day −/+ buttons live inside a single
    /// List row. Without an explicit per-button style, SwiftUI treats the
    /// whole row as one tap target and a tap fires BOTH actions (or none),
    /// so the count never changes.
    @MainActor
    func testAlertsPerDayIncrementChangesCount() throws {
        let app = launchToNotificationSettings()

        let count = app.staticTexts["alerts-per-day-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let before = Int(count.label) ?? -1
        XCTAssertGreaterThan(before, 0, "count should render a number")

        let increment = app.buttons["alerts-per-day-increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()

        let incremented = app.staticTexts["alerts-per-day-count"]
        XCTAssertTrue(
            waitForLabel(of: incremented, toEqual: "\(before + 1)"),
            "tapping + should increment the count (was \(before), still \(incremented.label))"
        )

        // Decrement must also fire independently — back to the start value.
        app.buttons["alerts-per-day-decrement"].tap()
        XCTAssertTrue(
            waitForLabel(of: count, toEqual: "\(before)"),
            "tapping − should decrement the count back to \(before)"
        )
    }

    /// Same mechanism for the nag stepper rows: each row hosts two Buttons,
    /// so each needs its own tap target. Exercises the remind-after row.
    @MainActor
    func testNagStepperRowsRespondToTaps() throws {
        let app = launchToNotificationSettings()

        // The nag section sits below the fold since the SLEEP section landed
        // (plan 39) — scroll it into view (off-screen SwiftUI List rows
        // aren't in the AX tree; the digest-suite precedent).
        let nagToggle = app.switches["nag-enabled"]
        var scrolls = 0
        while !nagToggle.exists && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(nagToggle.waitForExistence(timeout: 10))
        if (nagToggle.value as? String) != "1" {
            nagToggle.switches.firstMatch.tap()
        }

        let value = app.staticTexts["nag-delay-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        let before = value.label

        app.buttons["nag-delay-increment"].tap()
        XCTAssertTrue(
            waitForLabelChange(of: value, from: before),
            "tapping + on Remind after should change the value (still \(value.label))"
        )
    }

    @MainActor
    private func waitForLabel(of element: XCUIElement, toEqual expected: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func waitForLabelChange(of element: XCUIElement, from previous: String) -> Bool {
        let predicate = NSPredicate(format: "label != %@", previous)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
