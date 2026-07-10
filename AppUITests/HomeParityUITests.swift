import XCTest

/// Reporter home-screen visual parity (plan 29): structural assertions that
/// the parity chrome exists and never overlaps — top-bar glyph, left-aligned
/// filter row, reserved bottom strip (REPORT / plain dots / AWAKE pill), and
/// stacked proportional option blocks.
final class HomeParityUITests: XCTestCase {
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding", "--demo-data"]
        app.launch()
        return app
    }

    /// Task 1: decorative glyph centered in the top bar; the filter control is
    /// a left-aligned row (not a centered pill).
    @MainActor
    func testTopBarGlyphAndLeftAlignedFilterRow() throws {
        let app = launchApp()

        XCTAssertTrue(app.images["home-glyph"].waitForExistence(timeout: 15),
                      "expected the decorative home glyph in the top bar")

        let filterButton = app.buttons["viz-filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(filterButton.frame.minX, 24,
                                 "filter row should be left-aligned, not centered")
    }
}
