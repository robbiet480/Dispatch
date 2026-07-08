import XCTest

final class AppLockUITests: XCTestCase {
    @MainActor
    func testAppLockGatesHomeUntilUnlocked() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors", "--enable-app-lock", "--skip-onboarding"]
        app.launch()

        let lockView = app.otherElements["app-lock-view"]
        XCTAssertTrue(lockView.waitForExistence(timeout: 10))

        // The lock cover must fully gate Home: the report button exists in
        // the view hierarchy behind it but must not be hittable while locked.
        XCTAssertFalse(app.buttons["report-button"].isHittable)

        let unlockButton = app.buttons["app-lock-unlock-button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10))
        unlockButton.tap()

        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["report-button"].isHittable)
        XCTAssertFalse(lockView.exists)
    }
}
