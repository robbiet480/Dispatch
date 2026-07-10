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
    }
}
