import XCTest

/// Regression coverage for the shipped TestFlight build-30 crash: opening the
/// **Catalog** detail pane terminated the Mac app immediately with
///
///   NSInternalInconsistencyException — NSToolbar … already contains an item
///   with the identifier com.apple.SwiftUI.search. Duplicate items of this
///   type are not allowed.
///
/// Root cause: the split view's sidebar (`MacReportsListView`) and the catalog
/// detail pane (`MacCatalogView`) both carried a `.searchable`, and both
/// columns are alive at once — so both tried to add the single
/// `com.apple.SwiftUI.search` item to the one window toolbar. The catalog was
/// the only detail pane with a `.searchable`, which is why only it crashed.
///
/// This drives the real navigation the owner used to reproduce it: launch,
/// invoke Manage → Question Catalog (⌘5), and assert the catalog actually renders.
/// Before the fix the app is gone by the time we look for the list; after the
/// fix the stubbed catalog entries render.
final class MacCatalogUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Same fixture the dashboard smoke test seeds: mock sensors + in-memory
        // store + curated demo data. Under --ui-testing the catalog is backed
        // by StubCatalogProvider (four fixed entries), never real CloudKit.
        app.launchArguments = ["--mock-sensors", "--ui-testing", "--demo-data"]
        app.launch()
        return app
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 10) {
            // WindowGroup honors ⌘N if the launch landed without a main window.
            app.activate()
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 15), "main window should appear")
        return window
    }

    /// Opening the Catalog pane must not crash the app: the catalog view
    /// renders (stubbed entries → `mac-catalog-list`) and the process stays up.
    @MainActor
    func testOpeningCatalogPaneDoesNotCrash() throws {
        let app = launchApp()
        _ = mainWindow(app)

        // Navigate to the Catalog pane by KEYBOARD (⌘5 — the Manage menu's
        // "Question Catalog" command, plan 47), not by clicking the menu and not
        // via the detail toolbar's segmented picker.
        //
        // Not the picker: the `.principal` toolbar picker overflows on a narrow
        // window (as on CI, which uses the default window size — the screenshot
        // suite only sees it because it launches with --screenshot-window).
        //
        // Not the menu CLICK: driving the menu bar flakes ("timed out while
        // waiting for menu open notification") — MacScreenshotTests hit exactly
        // that and moved to ⌘2 for the same reason. The shortcut invokes the same
        // command without opening the menu, so it exercises the identical
        // navigation path with none of the AppKit menu-tracking timing.
        //
        // Reaching the catalog is what triggered the crash — pre-fix it brought a
        // second `.searchable` into the shared window toolbar and AppKit threw.
        app.activate()
        app.typeKey("5", modifierFlags: .command)

        // On macOS the catalog list surfaces as `question-catalog-list`: the
        // shared CatalogListView applies `mac-catalog-list` to the inner List,
        // but on the AppKit Outline the enclosing Group's `question-catalog-list`
        // wins, so that's the identifier that resolves here (mac-catalog-list is
        // absent in the macOS a11y tree). The split view shows the sidebar at
        // this window width (the toolbar toggle reads "Hide Sidebar"), so the
        // list, its detail, and the entries are all on screen. (Loading/empty
        // are accepted too so the assertion proves "did not crash", not a shape.)
        let list = app.descendants(matching: .any)
            .matching(identifier: "question-catalog-list").firstMatch
        let empty = app.descendants(matching: .any)
            .matching(identifier: "catalog-empty").firstMatch
        let loading = app.descendants(matching: .any)
            .matching(identifier: "catalog-loading").firstMatch
        let catalogAppeared = list.waitForExistence(timeout: 20)
            || empty.waitForExistence(timeout: 2)
            || loading.waitForExistence(timeout: 2)
        XCTAssertTrue(catalogAppeared,
                      "catalog view should render after selecting the Catalog pane (no crash)")

        // The app must still be running — a duplicate-searchable crash would
        // have torn it down.
        XCTAssertEqual(app.state, .runningForeground,
                       "the app should still be alive after opening the catalog")

        // Sanity: the stubbed entries populated the list. Rows render uppercased
        // (the app's list casing), so match the stub prompt case-insensitively.
        let waterRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        "drink water", "drink water")
        ).firstMatch
        XCTAssertTrue(waterRow.waitForExistence(timeout: 10),
                      "expected the stubbed catalog entries to render")
    }
}
