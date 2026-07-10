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

    /// Task 3: reserved bottom strip — REPORT, plain page dots, and the AWAKE
    /// pill coexist there, and chart content never enters the strip.
    @MainActor
    func testBottomStripChromeAndNonOverlap() throws {
        let app = launchApp()

        let awakeToggle = app.buttons["awake-toggle"]
        XCTAssertTrue(awakeToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(awakeToggle.label == "AWAKE" || awakeToggle.label == "ASLEEP")

        XCTAssertTrue(app.otherElements["page-dots"].exists || app.images["page-dots"].exists,
                      "expected the plain page-dots strip in the bottom toolbar")

        // First demo page is multiple-choice: its stacked blocks must end
        // above the reserved strip (never overlap the REPORT button's row).
        let optionShares = app.otherElements["viz-option-shares"].firstMatch
        XCTAssertTrue(optionShares.waitForExistence(timeout: 10))
        let reportButton = app.buttons["report-button"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(optionShares.frame.maxY, reportButton.frame.minY,
                                 "chart content must not enter the reserved bottom strip")
    }
}
