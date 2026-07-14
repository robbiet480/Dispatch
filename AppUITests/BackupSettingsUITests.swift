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
        // The Data section renders below the fold after the Settings "Manage"
        // section (Task 3.6) pushed the lower sections down; SwiftUI's List
        // lazily materializes off-screen rows, so scroll it in before asserting
        // (same idiom as testICloudScreenBackUpNowButtonAndCaption below).
        XCTAssertTrue(app.buttons["questions-settings-link"].waitForExistence(timeout: 10))
        let dataLink = app.buttons["data-settings-link"]
        var dataScrolls = 0
        while !dataLink.isHittable, dataScrolls < 8 {
            app.swipeUp()
            dataScrolls += 1
        }
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
        // The Data section renders below the fold on compact iPhone widths, and
        // SwiftUI's List lazily materializes off-screen rows — so the row isn't
        // in the accessibility tree until scrolled near. Scroll it in first,
        // then assert + tap (asserting before scrolling races the lazy render).
        var iCloudScrolls = 0
        while !iCloudLink.isHittable, iCloudScrolls < 8 {
            app.swipeUp()
            iCloudScrolls += 1
        }
        XCTAssertTrue(iCloudLink.waitForExistence(timeout: 5),
                      "icloud-settings-link should be reachable after scrolling")
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
