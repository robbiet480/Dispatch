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

    /// The "Spotlight Search While Locked" row is only meaningful while app
    /// lock is enabled: it must appear (defaulting OFF) under the Face ID
    /// toggle when lock is on, and disappear when lock is turned off.
    ///
    /// Only row visibility and the default are assertable here: the actual
    /// CoreSpotlight index isn't reachable from UI tests, and SpotlightIndexer
    /// deliberately no-ops under `--ui-testing`. The gate decision itself is
    /// unit-tested via `AppLockPolicy.allowsSpotlightIndexing` in DispatchKit.
    @MainActor
    func testSpotlightWhileLockedRowFollowsAppLockToggle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-sensors", "--enable-app-lock", "--skip-onboarding"]
        app.launch()

        let unlockButton = app.buttons["app-lock-unlock-button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10))
        unlockButton.tap()

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        // Row present while lock is on, and defaults to OFF. The Privacy
        // section sits below the fold after the Settings "Manage" section
        // (Task 3.6) pushed the lower sections down; SwiftUI's List lazily
        // materializes off-screen rows, so scroll it in before asserting.
        XCTAssertTrue(app.buttons["questions-settings-link"].waitForExistence(timeout: 10))
        let spotlightToggle = app.switches["spotlight-while-locked-toggle"]
        var spotlightScrolls = 0
        while !spotlightToggle.isHittable, spotlightScrolls < 8 {
            app.swipeUp()
            spotlightScrolls += 1
        }
        XCTAssertTrue(spotlightToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(spotlightToggle.value as? String, "0")

        // Turning app lock off hides the row (indexing always happens then).
        // SwiftUI Toggles expose an outer container Switch plus the inner
        // UISwitch — drill into the inner one (see NavigationUITests).
        let lockToggle = app.switches["app-lock-toggle"]
        XCTAssertTrue(lockToggle.waitForExistence(timeout: 10))
        let innerLockToggle = lockToggle.switches.firstMatch
        XCTAssertTrue(innerLockToggle.waitForExistence(timeout: 10))
        innerLockToggle.tap()
        XCTAssertTrue(spotlightToggle.waitForNonExistence(timeout: 10))
    }
}
