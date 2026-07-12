import XCTest

final class BackupSettingsUITests: XCTestCase {
    /// Plan 25: the Backups section renders the destination picker, and the
    /// stubbed test environment (BackupManager never touches the real
    /// ubiquity API under test args, so iCloud resolves as unavailable)
    /// surfaces the "iCloud Drive unavailable" status line in the footer.
    @MainActor
    func testBackupDestinationPickerAndUnavailableStatusLine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].tap()
        let dataLink = app.buttons["data-settings-link"]
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()

        // Destination picker present in the Backups section.
        let picker = app.descendants(matching: .any)["backup-destination"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))

        // Footer surfaces the stubbed-unavailable status (default mode is
        // Both, so the unavailability is worth telling the user about).
        let caption = app.staticTexts["backup-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        XCTAssertTrue(caption.label.contains("iCloud Drive unavailable"),
                      "caption should surface the unavailable state, got: \(caption.label)")
        XCTAssertTrue(caption.label.contains("On My iPhone"),
                      "Files hint should point at the local copy, got: \(caption.label)")
    }

    /// The iCloud settings screen carries its own "Back Up Now" (same shared
    /// BackupManager action as the Data screen) with a status caption.
    @MainActor
    func testICloudScreenBackUpNowButtonAndCaption() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()

        app.buttons["settings-button"].tap()
        let iCloudLink = app.buttons["icloud-settings-link"]
        XCTAssertTrue(iCloudLink.waitForExistence(timeout: 10))
        // The Data section sits below the schedule/survey rows, so on compact
        // iPhone widths icloud-settings-link starts below the fold — scroll it
        // into view before tapping (waitForExistence is true even off-screen).
        var iCloudScrolls = 0
        while !iCloudLink.isHittable, iCloudScrolls < 6 {
            app.swipeUp()
            iCloudScrolls += 1
        }
        iCloudLink.tap()

        let backUpNow = app.buttons["backup-now-icloud"]
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 10))
        XCTAssertEqual(backUpNow.label, "Back Up Now")
        XCTAssertTrue(backUpNow.isEnabled)

        let caption = app.staticTexts["backup-caption-icloud"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10))
        XCTAssertTrue(caption.label.contains("No backups yet")
                          || caption.label.contains("Last backup"),
                      "caption should show backup status, got: \(caption.label)")

        // Tapping is safe under test args (BackupManager skips all I/O in
        // the test environment) and must not disable the button forever.
        backUpNow.tap()
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 5))
    }
}
