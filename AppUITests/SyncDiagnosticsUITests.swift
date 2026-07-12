import XCTest

/// Plan 37: the sync diagnostics screen is reachable from Settings → iCloud →
/// Diagnostics and renders (empty data, "—" account) under test args, with the
/// privacy-safe export control present.
final class SyncDiagnosticsUITests: XCTestCase {
    @MainActor
    func testDiagnosticsScreenReachableWithExportButton() throws {
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

        let diagnosticsLink = app.buttons["sync-diagnostics-link"]
        XCTAssertTrue(diagnosticsLink.waitForExistence(timeout: 10))
        diagnosticsLink.tap()

        // Under test args the events section shows its empty state (no sync
        // events, no CloudKit account call) — confirms the screen rendered.
        let emptyEvents = app.staticTexts["sync-diagnostics-events-empty"]
        XCTAssertTrue(emptyEvents.waitForExistence(timeout: 10))

        // The privacy-safe export control is present (last section — scroll
        // it into view first).
        let export = app.buttons["sync-diagnostics-export"]
        var attempts = 0
        while !export.exists && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(export.waitForExistence(timeout: 10))
    }
}
