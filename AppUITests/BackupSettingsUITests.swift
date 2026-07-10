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
}
