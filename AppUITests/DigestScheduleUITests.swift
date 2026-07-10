import XCTest

/// Drives the digest schedule editor (plan 40): add a schedule via the sheet,
/// toggle its per-row enable switch, and swipe-to-delete. Asserts through the
/// UI — the store round-trip is exercised by the kit's persistence tests.
final class DigestScheduleUITests: XCTestCase {
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

    @MainActor
    private func scrollToDigestAddButton(_ app: XCUIApplication) -> XCUIElement {
        let addButton = app.buttons["digest-add-schedule"]
        // The digest section is last in the list — scroll it into view.
        for _ in 0..<8 where !addButton.exists {
            app.swipeUp()
        }
        return addButton
    }

    @MainActor
    private func addSchedule(_ app: XCUIApplication, cadence: String) {
        let addButton = scrollToDigestAddButton(app)
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()

        let cadencePicker = app.segmentedControls["digest-cadence-picker"]
        XCTAssertTrue(cadencePicker.waitForExistence(timeout: 10))
        cadencePicker.buttons[cadence].tap()

        app.buttons["digest-add-confirm"].tap()
    }

    @MainActor
    func testAddToggleAndDeleteAMonthlySchedule() throws {
        let app = launchToNotificationSettings()

        addSchedule(app, cadence: "Monthly")

        // A row labelled for the new monthly schedule appears.
        let monthlyRow = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH 'digest-schedule-toggle-'")
        ).firstMatch
        XCTAssertTrue(monthlyRow.waitForExistence(timeout: 10),
                      "expected a digest schedule row after adding")
        XCTAssertTrue(monthlyRow.label.contains("Monthly"),
                      "expected the row label to name the cadence, got: \(monthlyRow.label)")

        // Toggle it off, then back on.
        XCTAssertEqual(monthlyRow.value as? String, "1")
        monthlyRow.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(of: monthlyRow, toEqual: "0"))
        monthlyRow.switches.firstMatch.tap()
        XCTAssertTrue(waitForValue(of: monthlyRow, toEqual: "1"))

        // Swipe-to-delete removes it.
        monthlyRow.swipeLeft()
        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()
        XCTAssertTrue(waitForDisappearance(of: monthlyRow),
                      "expected the row to be removed after delete")
    }

    @MainActor
    private func waitForValue(of element: XCUIElement, toEqual expected: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
