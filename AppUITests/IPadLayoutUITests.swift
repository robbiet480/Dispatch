import UIKit
import XCTest

/// iPad regular-width layout coverage (ipad-ui-suite triage, 2026-07).
///
/// The UI suite historically only ran on iPhone, so a few tests baked in
/// compact-width assumptions. On iPad a `.sheet` presents as a centered
/// form-sheet card that is shorter than an iPhone's near-full-height sheet, so
/// once the catalog "Submit a Question" form adds a number question's INPUT
/// STYLE + DEFAULT ANSWER sections (with the keyboard up) the trailing
/// PLACEHOLDER row falls below the fold. Because it's a `List`, off-screen
/// rows aren't realized in the accessibility tree at all — so a test that taps
/// them without scrolling passes on a tall iPhone and fails on iPad.
///
/// These tests assert the iPad-adaptive behavior directly (readable column;
/// every submit-form field reachable via scrolling) and skip on compact-width
/// runners where there is nothing iPad-specific to check.
final class IPadLayoutUITests: XCTestCase {
    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()
        return app
    }

    /// Navigate Home → Settings → Questions → Question Catalog → Submit.
    @MainActor
    private func openSubmitForm(_ app: XCUIApplication) {
        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()
        let submitButton = app.buttons["catalog-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.tap()
    }

    /// On iPad's shorter form-sheet card, switching to a Number question adds
    /// the INPUT STYLE + DEFAULT ANSWER sections that push PLACEHOLDER below
    /// the fold. This guards the regression: after those sections appear, the
    /// trailing PLACEHOLDER field must still be reachable (scrolling allowed,
    /// matching the rest of the suite's idiom). Before the scroll, XCUITest
    /// couldn't find the unrealized `List` row at all on iPad.
    @MainActor
    func testSubmitFormTrailingFieldsReachableOnIPad() throws {
        try XCTSkipUnless(isPad, "iPad-only: on a tall iPhone sheet these rows are already realized")

        let app = launchApp()
        openSubmitForm(app)

        // The prompt is a vertical-axis TextField, which XCUITest can surface
        // as either a textField or a textView (same fallback as CatalogUITests).
        let promptField = app.textFields["catalog-submit-prompt"]
            .exists ? app.textFields["catalog-submit-prompt"] : app.textViews["catalog-submit-prompt"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()
        promptField.typeText("How loud was it?")

        // Switch the question to Number, which inserts INPUT STYLE + DEFAULT
        // ANSWER above PLACEHOLDER — the sections that push it off-fold.
        app.buttons["catalog-submit-type"].firstMatch.tap()
        let numberOption = app.buttons["Number"].firstMatch
        XCTAssertTrue(numberOption.waitForExistence(timeout: 10))
        numberOption.tap()
        XCTAssertTrue(app.textFields["catalog-submit-default-answer"].waitForExistence(timeout: 10))

        // The trailing PLACEHOLDER field must be reachable.
        let placeholderField = app.textFields["catalog-submit-placeholder"]
        var scrolls = 6
        while !placeholderField.exists, scrolls > 0 { app.swipeUp(); scrolls -= 1 }
        XCTAssertTrue(placeholderField.exists,
                      "PLACEHOLDER field should be reachable on iPad after the number sections appear")
    }

    /// Plan 27's readable column keeps the catalog list from stretching
    /// edge-to-edge on wide iPad layouts: a row's content should not span the
    /// full window width.
    @MainActor
    func testCatalogListHonorsReadableColumnOnIPad() throws {
        try XCTSkipUnless(isPad, "iPad-only: readableColumn is a no-op at compact width")

        let app = launchApp()
        app.buttons["settings-button"].firstMatch.tap()
        let questionsLink = app.buttons["questions-settings-link"]
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 10))
        questionsLink.tap()
        let catalogLink = app.buttons["question-catalog-link"]
        XCTAssertTrue(catalogLink.waitForExistence(timeout: 10))
        catalogLink.tap()

        let firstEntry = app.staticTexts["DID YOU DRINK WATER TODAY?"]
        XCTAssertTrue(firstEntry.waitForExistence(timeout: 15))

        // Only meaningful when the window is wide enough for the 640pt
        // readable-column cap to bite (full-screen 13" iPad). In split view /
        // slide over the list may legitimately span the window.
        let windowWidth = app.windows.firstMatch.frame.width
        try XCTSkipUnless(windowWidth > 800,
                          "window too narrow for the readable-column cap to matter")

        // Measure the row CELL, not the staticText: the label's frame is
        // intrinsic (it stays narrow regardless of the row width), so only the
        // cell container is diagnostic of an edge-to-edge stretch.
        let firstCell = app.cells.containing(.staticText, identifier: "DID YOU DRINK WATER TODAY?").firstMatch
        XCTAssertTrue(firstCell.exists, "expected the catalog row cell containing the stub entry")
        XCTAssertLessThan(firstCell.frame.width, windowWidth - 80,
                          "catalog rows should be constrained to a readable column on iPad, not full width")
    }
}
