import XCTest

final class InsightsUITests: XCTestCase {
    /// The Insights screen opens from Settings and, on an empty in-memory
    /// store (--mock-sensors), renders the empty state explaining that
    /// insights need a couple of weeks of reports — the honesty guards mean
    /// a fresh install must show silence, not filler correlations.
    @MainActor
    func testInsightsOpensAndRendersEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let insightsLink = app.buttons["insights-link"]
        XCTAssertTrue(insightsLink.waitForExistence(timeout: 10))
        insightsLink.tap()

        // Combined accessibility elements surface with a backend-dependent
        // element type — match by identifier across any type.
        let emptyState = app.descendants(matching: .any)["insights-empty-state"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "expected the insights empty state on an empty store")
        XCTAssertTrue(emptyState.label.contains("two weeks"),
                      "empty state should explain the ~two-week requirement, got: \(emptyState.label)")
        XCTAssertFalse(app.descendants(matching: .any)["insight-card"].firstMatch.exists,
                       "no insight cards may render on an empty store")

        // Plan 34: an empty store has no drill-in-eligible question, so the
        // CORRELATIONS section is hidden and the unlock footnote explains
        // the 20-answer gate instead.
        XCTAssertFalse(app.descendants(matching: .any)["correlation-question-row"].firstMatch.exists,
                       "no correlation rows may render on an empty store")
        let footnote = app.descendants(matching: .any)["correlations-unlock-footnote"].firstMatch
        XCTAssertTrue(footnote.exists,
                      "the unlock footnote must explain the 20-answer gate")
    }

    /// Plan 34: with demo data (14 days × 2–3 answered reports per default
    /// question) at least one question clears the 20-answer gate; its
    /// drill-in renders rows and ALWAYS the correlation-≠-causation
    /// disclaimer.
    @MainActor
    func testCorrelationDrillInRendersWithDemoData() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding",
                               "--demo-data"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let insightsLink = app.buttons["insights-link"]
        XCTAssertTrue(insightsLink.waitForExistence(timeout: 10))
        insightsLink.tap()

        let questionRow = app.descendants(matching: .any)["correlation-question-row"].firstMatch
        XCTAssertTrue(questionRow.waitForExistence(timeout: 10),
                      "demo data must make at least one question drill-in eligible")
        // The section sits below the insight cards — bring it on screen.
        var scrolls = 0
        while !questionRow.isHittable && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        questionRow.tap()

        let drillIn = app.descendants(matching: .any)["question-correlations-view"].firstMatch
        XCTAssertTrue(drillIn.waitForExistence(timeout: 10))
        let disclaimer = app.descendants(matching: .any)["correlation-disclaimer"].firstMatch
        // The disclaimer is unconditional scroll content — scroll to the end
        // to reach it on small screens.
        var attempts = 0
        while !disclaimer.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(disclaimer.exists,
                      "the causation disclaimer must always render in the drill-in")
    }
}
