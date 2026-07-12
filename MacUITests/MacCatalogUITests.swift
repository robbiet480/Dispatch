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
/// click the `detail-pane-picker`'s "Catalog" segment, and assert the catalog
/// actually renders. Before the fix the app is gone by the time we look for
/// the list; after the fix the stubbed catalog entries render.
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

        // Navigate to the Catalog pane via the Manage menu (plan 47) rather than
        // the detail toolbar's segmented picker: the menu bar is always present,
        // whereas the `.principal` toolbar picker overflows on a narrow window
        // (as on CI, which uses the default window size — the screenshot suite
        // only sees it because it launches with --screenshot-window). Reaching
        // the catalog is what triggered the crash — pre-fix it brought a second
        // `.searchable` into the shared window toolbar and AppKit threw here.
        let manageMenu = app.menuBars.menuBarItems["Manage"]
        XCTAssertTrue(manageMenu.waitForExistence(timeout: 15),
                      "Manage menu should exist in the menu bar")
        manageMenu.click()
        let catalogItem = app.menuBars.menuItems["Question Catalog"]
        XCTAssertTrue(catalogItem.waitForExistence(timeout: 5),
                      "Manage → Question Catalog menu item should exist")
        catalogItem.click()

        // The catalog rendered — the stubbed provider yields four entries, so
        // the populated list appears. (Loading/empty are accepted too so the
        // assertion proves "did not crash", not a particular data shape.)
        let list = app.descendants(matching: .any)
            .matching(identifier: "mac-catalog-list").firstMatch
        let empty = app.descendants(matching: .any)
            .matching(identifier: "mac-catalog-empty").firstMatch
        let loading = app.descendants(matching: .any)
            .matching(identifier: "mac-catalog-loading").firstMatch
        let catalogAppeared = list.waitForExistence(timeout: 20)
            || empty.waitForExistence(timeout: 2)
            || loading.waitForExistence(timeout: 2)
        XCTAssertTrue(catalogAppeared,
                      "catalog view should render after selecting the Catalog pane (no crash)")

        // The app must still be running — a duplicate-searchable crash would
        // have torn it down.
        XCTAssertEqual(app.state, .runningForeground,
                       "the app should still be alive after opening the catalog")

        // Sanity: the stubbed entries actually populated the list.
        XCTAssertTrue(app.staticTexts["Did you drink water today?"].waitForExistence(timeout: 10),
                      "expected the stubbed catalog entries to render")
    }
}
