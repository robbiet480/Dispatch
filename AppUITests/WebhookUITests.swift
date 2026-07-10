import XCTest

final class WebhookUITests: XCTestCase {
    /// Plan 24: configure a webhook against the stub transport
    /// (`--stub-webhook` — always answers 200; no test touches the real
    /// network), file a report, and assert the settings status row shows
    /// the delivery.
    @MainActor
    func testConfiguredWebhookDeliversOnReportSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding",
                               "--stub-webhook"]
        app.launch()

        // Settings → Data → Advanced → Webhook.
        app.buttons["settings-button"].tap()
        let dataLink = app.buttons["data-settings-link"]
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()
        let webhookLink = app.buttons["webhook-settings-link"]
        XCTAssertTrue(webhookLink.waitForExistence(timeout: 10))
        webhookLink.tap()

        // Enable + configure an HTTPS URL (accepted by the URL rule; the
        // stub transport means it is never actually contacted). Row toggles
        // expose an outer container Switch plus the inner UISwitch — drill
        // into the inner one (see NavigationUITests for the rationale).
        let toggle = app.switches["webhook-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let innerToggle = toggle.switches.firstMatch
        XCTAssertTrue(innerToggle.waitForExistence(timeout: 10))
        innerToggle.tap()
        let urlField = app.textFields["webhook-url"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        urlField.tap()
        urlField.typeText("https://example.com/webhook")

        // Status row starts empty.
        let status = app.otherElements["webhook-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        // Send Test exercises the same transport path and reports inline.
        app.buttons["webhook-test"].tap()
        let testResult = app.staticTexts["webhook-test-result"]
        XCTAssertTrue(testResult.waitForExistence(timeout: 10))
        XCTAssertTrue(testResult.label.contains("Test delivered"),
                      "expected the stubbed test send to succeed, got: \(testResult.label)")

        // Back out to Home and file a report through the survey.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reportButton = app.buttons["report-button"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 10))
        reportButton.tap()
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        // The post-save enqueue+drain hits the stub → status row shows the
        // delivery.
        app.buttons["settings-button"].tap()
        XCTAssertTrue(dataLink.waitForExistence(timeout: 10))
        dataLink.tap()
        XCTAssertTrue(webhookLink.waitForExistence(timeout: 10))
        webhookLink.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let delivered = NSPredicate(format: "label CONTAINS 'Delivered'")
        let deliveredText = app.staticTexts.matching(delivered).firstMatch
        XCTAssertTrue(deliveredText.waitForExistence(timeout: 10),
                      "status row should show a delivered webhook")
    }
}
