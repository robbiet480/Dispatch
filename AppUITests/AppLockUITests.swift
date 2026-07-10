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

    /// Backgrounding and reactivating while locked must keep the window-level
    /// lock surface frontmost the whole time: the `.inactive`/`.background`
    /// cover path is a no-op while already locked (so it can't disturb the
    /// unlock flow), and the cover window must survive the round trip so no
    /// content is hittable on return.
    ///
    /// Note: the covered-but-not-locked path (grace interval) can't be
    /// exercised under UI tests — `coverForBackgroundingIfNeeded` is
    /// deliberately a no-op in the test environment so ordinary suites that
    /// background the app never trip the privacy cover.
    @MainActor
    func testLockSurfaceStaysFrontmostAcrossBackgrounding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors", "--enable-app-lock", "--skip-onboarding"]
        app.launch()

        let lockView = app.otherElements["app-lock-view"]
        XCTAssertTrue(lockView.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()

        // Immediately on reactivation the lock surface is present and content
        // behind it is not hittable — no flash of app content.
        XCTAssertTrue(lockView.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["report-button"].isHittable)

        let unlockButton = app.buttons["app-lock-unlock-button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10))
        unlockButton.tap()

        XCTAssertTrue(app.buttons["report-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["report-button"].isHittable)
        XCTAssertFalse(lockView.exists)
    }

    /// A URL opened while the app is locked must be queued behind the lock —
    /// not processed invisibly, not dropped — and must route after a
    /// successful unlock. Exercises the same queue-until-unlocked path the
    /// Spotify OAuth callback uses (dispatch-spotify:// itself no-ops in the
    /// test environment, so the widget deep link stands in as the routed
    /// observable: it presents the survey).
    @MainActor
    func testURLOpenedWhileLockedQueuesUntilUnlock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors", "--enable-app-lock", "--skip-onboarding"]
        app.launch()

        let lockView = app.otherElements["app-lock-view"]
        XCTAssertTrue(lockView.waitForExistence(timeout: 10))

        // System-initiated deep link — unlike XCUIApplication.open(_:), this
        // delivers custom schemes without an "Open in Dispatch?" confirmation.
        XCUIDevice.shared.system.open(URL(string: "dispatch://report")!)

        // Still locked: the lock surface stays frontmost and the survey the
        // URL requests must NOT present while locked.
        XCTAssertTrue(lockView.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["survey-next"].exists)

        let unlockButton = app.buttons["app-lock-unlock-button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10))
        unlockButton.tap()

        // Unlock drains the queue: the deferred URL routes and the survey
        // presents without any further interaction. (survey-next, not
        // survey-progress: with the lock cover window just torn down, the
        // decorative progress bar doesn't resolve as a queryable element on
        // this presentation path, while the footer button always does.)
        XCTAssertTrue(app.buttons["survey-next"].waitForExistence(timeout: 10))
        XCTAssertFalse(lockView.exists)
    }
}
