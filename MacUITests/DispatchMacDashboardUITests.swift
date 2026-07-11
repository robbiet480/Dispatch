import XCTest

/// Mac dashboard smoke test — the desktop sibling of the iOS home/search
/// coverage. Verifies the search-filter wiring fixed on main (57b93b9):
/// the sidebar search feeds the dashboard's `report-count` label and the
/// chart grid, so typing a query that matches a SUBSET of the demo reports
/// shrinks the dashboard's own count — not just the sidebar list.
///
/// Unlike MacScreenshotTests this is NOT gated on SCREENSHOT_MODE: it runs as
/// part of the ordinary DispatchMacUITests suite.
final class DispatchMacDashboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Same fixture the screenshot suite seeds, minus the screenshot-only
        // window/theme args: mock sensors + in-memory store + curated demo data.
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--demo-data"]
        app.launch()
        return app
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 10) {
            // WindowGroup honors ⌘N if the launch landed without a main window.
            app.activate()
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 15), "main window should appear")
        return window
    }

    /// The "N reports" string for the count element. On macOS a SwiftUI `Text`
    /// exposes its content as the accessibility *value* (AppKit), where iOS
    /// surfaces it as the *label* — read whichever is populated.
    private func countText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Parses the leading integer out of a "N reports" string.
    private func reportCount(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    @MainActor
    func testDashboardPopulatedAndSearchFiltersCharts() throws {
        let app = launchApp()
        _ = mainWindow(app)

        // 1) Dashboard is populated: the chart grid and the count label exist.
        let vizGrid = app.descendants(matching: .any).matching(identifier: "viz-grid").firstMatch
        XCTAssertTrue(vizGrid.waitForExistence(timeout: 15), "viz-grid should render for demo data")

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 15), "report-count label should exist")

        let initialText = countText(countLabel)
        guard let initialCount = reportCount(initialText) else {
            XCTFail("could not parse report-count from: '\(initialText)'")
            return
        }
        // The demo fixture seeds many reports across 14 days; expect well more
        // than one so a subset search has room to shrink the count.
        XCTAssertGreaterThan(initialCount, 1, "demo data should seed multiple reports (got \(initialCount))")

        // 2) Search a term that matches a SUBSET. "coffee" appears as an
        // activity token / note on some reports but not all — and never on the
        // location-less wake reports — so the search-filtered count must drop
        // while remaining non-zero. ⌘F focuses the .searchable field (same path
        // the screenshot suite exercises).
        app.typeKey("f", modifierFlags: .command)
        app.typeText("coffee")

        // Wait for the count to reflect the filtered set (value or label
        // changes away from the initial "N reports" string).
        let changed = NSPredicate { element, _ in
            self.countText(element as! XCUIElement) != initialText
        }
        expectation(for: changed, evaluatedWith: countLabel)
        waitForExpectations(timeout: 10)

        let filteredText = countText(countLabel)
        guard let filteredCount = reportCount(filteredText) else {
            XCTFail("could not parse filtered report-count from: '\(filteredText)'")
            return
        }
        XCTAssertLessThan(filteredCount, initialCount,
                          "search should shrink the dashboard count (\(filteredCount) vs \(initialCount))")
        XCTAssertGreaterThan(filteredCount, 0,
                             "'coffee' should still match a subset of demo reports")
        // The chart grid must survive the filter (reports still non-empty).
        XCTAssertTrue(vizGrid.waitForExistence(timeout: 10),
                      "viz-grid should still render for the filtered subset")

        // 3) Clearing the search restores the full count — proving the
        // dashboard count is driven live by the search set.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        let restored = NSPredicate { element, _ in
            self.reportCount(self.countText(element as! XCUIElement)) == initialCount
        }
        expectation(for: restored, evaluatedWith: countLabel)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(reportCount(countText(countLabel)), initialCount,
                       "clearing search should restore the full report count")
    }
}
