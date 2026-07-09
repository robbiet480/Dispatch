import XCTest

final class DigestUITests: XCTestCase {
    /// The digest screen opens from Settings and renders a narrative under
    /// --mock-sensors. The simulator/test path has no Apple Intelligence
    /// (DigestGenerator is test-gated to the template), so this
    /// deterministically exercises the template fallback: an empty in-memory
    /// store yields the exact zero-report template sentence.
    @MainActor
    func testWeeklyDigestOpensAndRendersTemplateNarrative() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let digestLink = app.buttons["weekly-digest-link"]
        XCTAssertTrue(digestLink.waitForExistence(timeout: 10))
        digestLink.tap()

        let narrative = app.staticTexts["digest-narrative"]
        XCTAssertTrue(narrative.waitForExistence(timeout: 10),
                      "expected the digest narrative to render")
        XCTAssertTrue(
            narrative.label.contains("You filed 0 reports this week"),
            "expected the deterministic template narrative, got: \(narrative.label)"
        )
    }
}
