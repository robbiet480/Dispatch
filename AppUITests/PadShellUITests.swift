import UIKit
import XCTest

/// Task 3.6 (iPad/Mac UI convergence): the iPad root is now the shared
/// `LargeScreenShell` — a top pane picker (`shell-pane-picker`) driving
/// side-by-side list + detail panes, the same shell the Mac adopted in 3.5.
///
/// This is the FIRST runtime exercise of the shared shell: the iPad simulator
/// never touches the user's Mac display (unlike the deferred macOS UI tests),
/// so this test is the real proof the shell renders and navigates at runtime.
/// It asserts the three things that prove the shell is live and side-by-side:
///   1. the pane picker exists,
///   2. the Catalog pane shows its list AND — after selecting an entry — the
///      detail preview appears BESIDE the still-visible list (a split, not a
///      push),
///   3. the Questions pane shows its own list.
///
/// The shell is the iPad root only; iPhone keeps `HomeView`, so this skips at
/// compact width. Landscape is forced so a two-column split reliably shows both
/// columns side-by-side regardless of the simulator's launch orientation — the
/// side-by-side layout is exactly what's under test.
final class PadShellUITests: XCTestCase {
    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Same fixture the sibling suite uses: mock sensors + in-memory store +
        // onboarding pre-completed (only --skip-onboarding sets OnboardingFlag,
        // so the shell is the first screen). Under --ui-testing the catalog is
        // backed by StubCatalogProvider (fixed entries), never real CloudKit.
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--mock-sensors"]
        app.launch()
        return app
    }

    /// Runtime-verifies the shell on iPad: pane picker → Catalog list + detail
    /// side-by-side → Questions list.
    @MainActor
    func testShellPanePickerDrivesSideBySidePanes() throws {
        try XCTSkipUnless(isPad, "iPad-only: the shell is the iPad root; iPhone keeps HomeView (no pane picker)")

        // Landscape guarantees the two-column split shows both columns at once,
        // which is the side-by-side behavior under test.
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = launchApp()

        // (1) The pane picker exists — the shell's principal-toolbar segmented
        // Picker (queried the same way DigestScheduleUITests queries its
        // segmented control).
        let picker = app.segmentedControls["shell-pane-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "the shell's pane picker should exist on the iPad shell root")

        // (2) Switch to Catalog: its list appears in the sidebar column …
        picker.buttons["Catalog"].tap()

        let catalogList = app.descendants(matching: .any)
            .matching(identifier: "question-catalog-list").firstMatch
        XCTAssertTrue(catalogList.waitForExistence(timeout: 15),
                      "the Catalog pane's list should appear in the shell sidebar")

        // … and selecting an entry renders its input preview in the DETAIL
        // column, beside the list.
        catalogList.cells.firstMatch.tap()

        let preview = app.descendants(matching: .any)
            .matching(identifier: "question-input-preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "selecting a catalog entry should render its input preview in the detail column")

        // Side-by-side proof: the list is STILL on screen alongside the detail
        // preview. A push would have replaced the list; a split keeps both
        // visible at once.
        XCTAssertTrue(catalogList.exists,
                      "the catalog list should remain visible beside the detail preview (side-by-side, not a push)")

        // (3) Switch to Questions: its list appears.
        picker.buttons["Questions"].tap()

        let questionsList = app.descendants(matching: .any)
            .matching(identifier: "question-settings-list").firstMatch
        XCTAssertTrue(questionsList.waitForExistence(timeout: 15),
                      "the Questions pane's list should appear when switching to the Questions pane")
    }
}
