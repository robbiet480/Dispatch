import XCTest

/// Dynamic Type smoke test (plan 17): the whole run is pinned to
/// `.accessibility3` (UICTContentSizeCategoryAccessibilityXL) via the
/// UIKit launch-argument override, then drives home → survey → save.
/// XCUITest can't measure clipping, so the assertion is structural: the
/// controls a user must reach to file a report all exist and are hittable
/// at that size (a clipped/zero-frame control fails hittability).
final class AccessibilityUITests: XCTestCase {
    @MainActor
    func testSurveyFlowUsableAtAccessibility3TextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--mock-sensors", "--ui-testing", "--skip-onboarding",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
        ]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        let before = app.reportCountText()

        let reportButton = app.buttons["report-button"]
        XCTAssertTrue(reportButton.isHittable, "report button not hittable at accessibility3")
        reportButton.tap()

        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isHittable, "survey NEXT/DONE not hittable at accessibility3")

        // First seeded page is the Yes/No question — its choices must be
        // reachable at accessibility sizes. The page is a ScrollView and the
        // capture checklist above the question grows several screens tall at
        // accessibility3, so scrolling to reach the choices is expected
        // (content below the fold is NOT clipped); unreachable-after-
        // scrolling is the failure this guards against.
        let yes = app.buttons["Yes"]
        if yes.waitForExistence(timeout: 5) {
            var swipes = 0
            while !yes.isHittable && swipes < 6 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(yes.isHittable, "choice row not reachable at accessibility3")
            yes.tap()
        }

        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before, "report did not save at accessibility3")
    }
}
