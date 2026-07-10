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

    /// Task 4: option shares render as vertically STACKED full-width blocks
    /// (Reporter parity), not side-by-side columns — and each option keeps its
    /// per-block accessibility element.
    @MainActor
    func testOptionSharesBlocksStackVertically() throws {
        let app = launchApp()

        let optionShares = app.otherElements["viz-option-shares"].firstMatch
        XCTAssertTrue(optionShares.waitForExistence(timeout: 15))

        // Per-block a11y elements read "<Option>, NN percent". Queried
        // app-wide: the `.ignore` container flattening can hoist the block
        // elements out of the identified container's XCUI subtree.
        let blocks = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH ' percent'"))
        XCTAssertGreaterThanOrEqual(blocks.count, 2,
                                    "expected at least two option blocks with percent labels")

        let first = blocks.element(boundBy: 0).frame
        let second = blocks.element(boundBy: 1).frame
        XCTAssertEqual(first.minX, second.minX, accuracy: 1.0,
                       "stacked blocks share the same leading edge")
        XCTAssertGreaterThan(second.minY, first.maxY - 1.0,
                             "blocks must stack vertically, not sit side by side")
    }

    /// PR #41 review: 15 pages of dots (tiered shrink) must fit inside the
    /// bottom strip without colliding with the REPORT/AWAKE neighbors.
    @MainActor
    func testFifteenPageDotsFitBetweenStripNeighbors() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding",
                               "--demo-data", "--demo-many-questions"]
        app.launch()

        let dots = app.otherElements["page-dots"]
        XCTAssertTrue(dots.waitForExistence(timeout: 15))
        XCTAssertEqual(dots.label, "Page 1 of 15", "fixture should yield 15 pages")

        let report = app.buttons["report-button"]
        let awake = app.buttons["awake-toggle"]
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        XCTAssertTrue(awake.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(dots.frame.minX, report.frame.maxX,
                                    "dots must not collide with REPORT")
        XCTAssertLessThanOrEqual(dots.frame.maxX, awake.frame.minX,
                                 "dots must not collide with the AWAKE pill")
    }
}
