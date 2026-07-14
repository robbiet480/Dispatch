import UIKit
import XCTest

/// iPad regular-width layout coverage (ipad-ui-suite triage, 2026-07;
/// retargeted to the shared shell in Task 3.9).
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
/// Task 3.6 made `LargeScreenShell` the iPad root, so the catalog is no longer
/// reached through Settings → Questions → Question Catalog (that path is
/// iPhone-only now). On iPad the catalog is the shell's Catalog pane, selected
/// from the `shell-pane-picker`; its list lives in the split-view sidebar and
/// "Submit a Question" (`catalog-submit-button`) is a sidebar toolbar item.
/// Landscape is forced so the two-column split reliably shows the sidebar
/// (same reason as `PadShellUITests`).
///
/// These tests assert the iPad-adaptive behavior directly (the catalog list
/// stays a constrained column — now the shell sidebar — rather than stretching
/// edge-to-edge; every submit-form field reachable via scrolling) and skip on
/// compact-width runners where there is nothing iPad-specific to check.
final class IPadLayoutUITests: XCTestCase {
    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func tearDown() {
        // These tests force landscape; restore portrait so later portrait-only
        // classes in the same run aren't left rotated (device orientation is a
        // global simulator setting that persists across tests).
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--skip-onboarding"]
        app.launch()
        return app
    }

    /// Switch the shell to its Catalog pane and return the pane picker. The
    /// catalog list then renders in the sidebar column.
    @MainActor
    private func showCatalogPane(_ app: XCUIApplication) -> XCUIElement {
        let picker = app.segmentedControls["shell-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "the shell pane picker should exist on the iPad shell root")
        picker.buttons["Catalog"].tap()
        return picker
    }

    /// Shell Catalog pane → Submit a Question sheet.
    @MainActor
    private func openSubmitForm(_ app: XCUIApplication) {
        _ = showCatalogPane(app)
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

        // Landscape so the shell's two-column split reliably exposes the
        // sidebar (Catalog list + its toolbar), same as PadShellUITests.
        XCUIDevice.shared.orientation = .landscapeLeft

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

    /// On the iPad shell the catalog list is the split-view sidebar, so it
    /// stays a constrained column rather than stretching edge-to-edge: a row's
    /// content must not span the full window width. (Pre-3.6 this guarded
    /// Plan 27's 640pt readable-column cap on a full-width catalog; the shell
    /// now enforces the columnar layout structurally, which this still asserts.)
    @MainActor
    func testCatalogListHonorsReadableColumnOnIPad() throws {
        try XCTSkipUnless(isPad, "iPad-only: the shell sidebar is a no-op concept at compact width")

        // Landscape so the two-column split shows the sidebar (the catalog
        // list) beside the detail, rather than collapsing it behind a toggle.
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = launchApp()
        _ = showCatalogPane(app)

        let firstEntry = app.staticTexts["DID YOU DRINK WATER TODAY?"]
        XCTAssertTrue(firstEntry.waitForExistence(timeout: 15))

        // Only meaningful when the window is wide enough that a full-width
        // stretch would be visibly wrong (full-screen 13"/11" iPad). In split
        // view / slide over the layout may legitimately narrow.
        let windowWidth = app.windows.firstMatch.frame.width
        try XCTSkipUnless(windowWidth > 800,
                          "window too narrow for the sidebar-vs-full-width distinction to matter")

        // Measure the row CELL, not the staticText: the label's frame is
        // intrinsic (it stays narrow regardless of the row width), so only the
        // cell container is diagnostic of an edge-to-edge stretch.
        let firstCell = app.cells.containing(.staticText, identifier: "DID YOU DRINK WATER TODAY?").firstMatch
        XCTAssertTrue(firstCell.exists, "expected the catalog row cell containing the stub entry")
        XCTAssertLessThan(firstCell.frame.width, windowWidth - 80,
                          "catalog rows should be constrained to a readable column on iPad, not full width")
    }
}
