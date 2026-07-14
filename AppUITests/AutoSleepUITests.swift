import XCTest

/// Plan 39: the auto awake/asleep Settings toggle and the source-honest
/// hero captions. State is driven via launch arguments only (test gating
/// absolute — no HealthKit, no real Focus).
final class AutoSleepUITests: XCTestCase {
    /// Navigates to Settings → Notifications and returns the launched app.
    @MainActor
    private func launchToNotificationSettings(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
            + extraArguments
        app.launch()

        app.openSettings()

        let notificationsLink = app.buttons["notifications-settings-link"]
        XCTAssertTrue(notificationsLink.waitForExistence(timeout: 10))
        notificationsLink.tap()
        return app
    }

    /// The toggle exists in the SLEEP section, defaults OFF (a user who
    /// never opens it sees zero behavior change), and holds a flip.
    @MainActor
    func testAutoSleepToggleDefaultsOffAndHoldsFlip() throws {
        let app = launchToNotificationSettings()

        let toggle = app.switches["auto-sleep-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "auto-sleep must default OFF")

        // Tap the INNER switch — the outer element is the whole row (the
        // WebhookUITests precedent).
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(
            waitForValue(of: toggle, toEqual: "1"),
            "toggle should turn on when tapped (value: \(String(describing: toggle.value)))"
        )

        // Relaunch-free stability: the flip holds (no snap-back from a
        // failed prefs write — the onChange writes through to
        // NotificationPrefs and re-arms the observer).
        XCTAssertEqual(toggle.value as? String, "1", "toggle should stay on")
    }

    /// An automation-sourced asleep state renders the honest hero caption
    /// (frozen identifier `next-notification-source`, new text only for the
    /// non-manual source). `--auto-asleep` is the launch-argument hook that
    /// stands in for a Sleep Focus activation.
    @MainActor
    func testFocusSourcedAsleepShowsHonestHeroCaption() throws {
        let app = launchToNotificationSettings(extraArguments: ["--auto-asleep"])

        let source = app.staticTexts["next-notification-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForLabel(of: source, toEqual: "SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"),
            "hero caption should name the focus-filter source (was: \(source.label))"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func waitForLabel(of element: XCUIElement, toEqual expected: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    @MainActor
    private func waitForValue(of element: XCUIElement, toEqual expected: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }
}
