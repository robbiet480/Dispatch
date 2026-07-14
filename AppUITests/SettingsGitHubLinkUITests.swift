import XCTest

/// The Settings screen ends with a "View on GitHub" link to the project's
/// source repository. It's the last row, below the About section, so the
/// list must be scrolled to the bottom before the lazily-rendered row exists.
final class SettingsGitHubLinkUITests: XCTestCase {
    @MainActor
    func testGitHubLinkPresentAtBottomOfSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.openSettings()

        // The link is the final row, below the fold on compact iPhone widths.
        // SwiftUI's List lazily materializes off-screen rows, so scroll it into
        // view before asserting (asserting first races the lazy render).
        let githubLink = app.buttons["github-link"]
        var scrolls = 0
        while !githubLink.isHittable, scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(githubLink.waitForExistence(timeout: 5),
                      "github-link should be reachable at the bottom of Settings")
    }
}
