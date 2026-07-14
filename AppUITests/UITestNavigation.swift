import UIKit
import XCTest

/// Idiom-aware navigation helpers shared by the UI suite.
///
/// The iPad/Mac UI-convergence branch swapped the iPad root from the iPhone
/// `HomeView` to the shared `LargeScreenShell` (see `RootNavigationView`). The
/// suite was written against HomeView's chrome, which the shell replaced:
///   - Settings: HomeView's `settings-button` (a push) → the shell's trailing
///     `shell-settings-button` gear (presents `SettingsView` as a sheet).
///   - Reports: HomeView's `reports-list-button` (a push) → the always-present
///     split-view **sidebar** on the shell's Dashboard pane (`ReportsListView`,
///     rows keyed `report-row`).
///   - Questions / Prompt Groups / Catalog / Insights: on iPhone these are
///     rows inside `SettingsView`; on the shell they are top-level panes reached
///     from the `shell-pane-picker`, so `SettingsView` omits those links on iPad.
///
/// On the shell the pane lists (reports / questions / groups / catalog) live in
/// the `NavigationSplitView` **sidebar**, which is collapsed behind the system
/// "Show Sidebar" toggle at portrait regular width. `revealSidebar(until:)` taps
/// that toggle when the target row/list isn't already on screen (a no-op when it
/// is — e.g. landscape, or an already-open overlay). These helpers keep the one
/// suite driving both idioms; every assertion a caller makes AFTER navigation is
/// unchanged, because the destination views (SettingsView links, ReportsListView
/// rows, the catalog/questions/groups lists) are the same on both idioms.
extension XCUIApplication {
    /// True when this run targets the iPad shell rather than the iPhone HomeView.
    /// The shell is chosen by idiom in `RootNavigationView`, so the idiom is the
    /// correct gate (not the size class).
    @MainActor
    var isPadShell: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: - Sidebar reveal (iPad shell)

    /// Ensures the shell's split-view sidebar is showing so `target` (a sidebar
    /// row/list — `report-row`, `question-settings-list`, `group-add`,
    /// `question-catalog-list`, …) is reachable. Taps the standard
    /// `NavigationSplitView` "Show Sidebar" toolbar control only when `target`
    /// isn't already present (already-shown sidebar / landscape / open overlay).
    /// Harmless on iPhone (no such control), but callers only use it on iPad.
    @MainActor
    func revealSidebar(until target: XCUIElement, timeout: TimeInterval = 10) {
        if target.waitForExistence(timeout: 2) { return }
        let toggle = navigationBars.buttons["Show Sidebar"]
        if toggle.waitForExistence(timeout: 5) { toggle.tap() }
        _ = target.waitForExistence(timeout: timeout)
    }

    // MARK: - Settings

    /// Opens Settings. iPhone: taps `settings-button` (pushes `SettingsView`).
    /// iPad: taps the shell's `shell-settings-button` gear (presents
    /// `SettingsView` as a sheet). After it returns, the Settings links that
    /// exist on BOTH idioms (notifications / beacons / weekly-digest / people /
    /// sensors / data / icloud / app-lock / github / …) are queryable. The
    /// Questions/Groups/Catalog/Insights links are iPhone-only — use
    /// `openQuestions()` / `openGroups()` / `openCatalog()` / `openInsights()`.
    @MainActor
    func openSettings(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = isPadShell ? "shell-settings-button" : "settings-button"
        let button = buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: timeout),
                      "Settings entry '\(identifier)' not found", file: file, line: line)
        button.firstMatch.tap()
    }

    /// Dismisses Settings back to the app root. iPhone: pops via the nav-bar back
    /// button. iPad: the Settings sheet (a centered form sheet) has no Done button
    /// — the Mac keeps Settings in the app menu, iOS presents it modally — so tap
    /// the dimmed area outside the sheet to dismiss it. This works from ANY pushed
    /// screen inside the sheet (Data / Webhook / Sensors / …) without popping
    /// back to the root first. The dashboard's trailing gear (`shell-settings-
    /// button`) is only hittable once the modal is gone, so wait on that to
    /// guarantee the sheet is fully dismissed before returning.
    @MainActor
    func closeSettings() {
        if isPadShell {
            // The form sheet is horizontally centered; the far-left column is the
            // dimmed passthrough-blocking backdrop in both orientations.
            coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
            let gear = buttons["shell-settings-button"]
            let deadline = Date().addingTimeInterval(10)
            while !gear.isHittable, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        } else {
            navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    // MARK: - Reports

    /// Reveals the reports list. iPhone: taps `reports-list-button` (pushes
    /// `ReportsListView`). iPad: the reports list is the Dashboard pane's
    /// always-present sidebar, so this selects the Dashboard pane and reveals the
    /// sidebar. After it returns, `reports-list` and any `report-row` are
    /// reachable (the list renders even with zero reports).
    @MainActor
    func revealReports(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if isPadShell {
            selectPane("Dashboard")
            // Type-agnostic discovery: the row surfaces as a button (or cell)
            // and the list as a collectionView (or table); querying strict types
            // races the render and can miss the element (the same TOCTOU class
            // hardened in openFirstReportRow).
            let row = descendants(matching: .any).matching(identifier: "report-row").firstMatch
            let list = descendants(matching: .any).matching(identifier: "reports-list").firstMatch
            if row.waitForExistence(timeout: 2) || list.exists { return }
            let toggle = navigationBars.buttons["Show Sidebar"]
            if toggle.waitForExistence(timeout: 5) { toggle.tap() }
            if !row.waitForExistence(timeout: timeout) {
                _ = list.waitForExistence(timeout: 3)
            }
        } else {
            let button = buttons["reports-list-button"]
            XCTAssertTrue(button.waitForExistence(timeout: timeout),
                          "reports-list-button not found", file: file, line: line)
            button.tap()
        }
    }

    // MARK: - Dashboard report count

    /// The dashboard's "N reports" count string. iPhone's `HomeView` always
    /// shows the count (even "0 reports"); the iPad shell replaces the count
    /// with a "No reports yet" empty state when the store is empty, so this
    /// reports "0 reports" there — giving tests a uniform baseline that also
    /// serves as a dashboard-ready gate. Once any report exists the count is
    /// present on both idioms, so post-filing reads work unchanged.
    @MainActor
    func reportCountText(timeout: TimeInterval = 10) -> String {
        let count = staticTexts["report-count"]
        if count.waitForExistence(timeout: timeout) { return count.label }
        if isPadShell, staticTexts["No reports yet"].waitForExistence(timeout: 3) {
            return "0 reports"
        }
        return count.label
    }

    // MARK: - Reports list

    /// Waits for the reports list and taps its first `report-row`. Discovers
    /// both the list (`reports-list`: collectionView for the iOS List, table
    /// elsewhere) and the row (`report-row`: button or cell) by identifier with
    /// TYPE-AGNOSTIC queries — a slightly-late render can't bind `.exists` to
    /// the wrong element type (the TOCTOU flake). Call after `revealReports()`.
    @MainActor
    func openFirstReportRow(timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) {
        let list = descendants(matching: .any).matching(identifier: "reports-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: timeout),
                      "reports-list should exist", file: file, line: line)
        let firstRow = descendants(matching: .any).matching(identifier: "report-row").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: timeout),
                      "at least one report-row should exist", file: file, line: line)
        firstRow.tap()
    }

    // MARK: - Shell panes (iPad) ⇄ Settings links (iPhone)

    /// Selects a shell pane by its `shell-pane-picker` segment label
    /// ("Dashboard" / "Insights" / "Questions" / "Groups" / "Catalog"). The pane
    /// picker lives in the split-view **sidebar**'s toolbar, so at portrait
    /// regular width — where the sidebar is collapsed behind the system "Show
    /// Sidebar" control — it isn't present until the sidebar is revealed; this
    /// reveals it first when the picker is missing. No-op if the picker still
    /// can't be found (e.g. a modal is up); callers assert on the destination.
    @MainActor
    func selectPane(_ label: String) {
        let picker = segmentedControls["shell-pane-picker"]
        if !picker.waitForExistence(timeout: 5) {
            let toggle = navigationBars.buttons["Show Sidebar"]
            if toggle.waitForExistence(timeout: 5) { toggle.tap() }
        }
        guard picker.waitForExistence(timeout: 10) else { return }
        let segment = picker.buttons[label]
        if segment.waitForExistence(timeout: 5) { segment.tap() }
    }

    /// Opens the Questions management list. iPhone: Settings → Questions.
    /// iPad: the shell's Questions pane (list in the split-view sidebar). After
    /// it returns, `question-settings-list` and `add-question-button` are
    /// reachable on both idioms (both host the shared `QuestionsList`).
    @MainActor
    func openQuestions(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if isPadShell {
            selectPane("Questions")
            revealSidebar(until: buttons["add-question-button"], timeout: timeout)
        } else {
            openSettings(timeout: timeout, file: file, line: line)
            let link = buttons["questions-settings-link"]
            XCTAssertTrue(link.waitForExistence(timeout: timeout),
                          "questions-settings-link not found", file: file, line: line)
            link.tap()
        }
    }

    /// Opens the Prompt Groups management list. iPhone: Settings → Prompt Groups.
    /// iPad: the shell's Groups pane (list in the split-view sidebar). After it
    /// returns, `group-add` is reachable on both idioms.
    @MainActor
    func openGroups(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if isPadShell {
            selectPane("Groups")
            revealSidebar(until: buttons["group-add"], timeout: timeout)
        } else {
            openSettings(timeout: timeout, file: file, line: line)
            let link = buttons["prompt-groups-link"]
            XCTAssertTrue(link.waitForExistence(timeout: timeout),
                          "prompt-groups-link not found", file: file, line: line)
            link.tap()
        }
    }

    /// Opens the Question Catalog. iPhone: Settings → Questions → Question
    /// Catalog. iPad: the shell's Catalog pane (list in the split-view sidebar).
    /// After it returns, `question-catalog-list` and the sidebar toolbar's
    /// `catalog-submit-button` are reachable on both idioms (both host the shared
    /// `CatalogListView`).
    @MainActor
    func openCatalog(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if isPadShell {
            selectPane("Catalog")
            revealSidebar(until: descendants(matching: .any)
                .matching(identifier: "question-catalog-list").firstMatch, timeout: timeout)
        } else {
            openSettings(timeout: timeout, file: file, line: line)
            let questionsLink = buttons["questions-settings-link"]
            XCTAssertTrue(questionsLink.waitForExistence(timeout: timeout),
                          "questions-settings-link not found", file: file, line: line)
            questionsLink.tap()
            let catalogLink = buttons["question-catalog-link"]
            XCTAssertTrue(catalogLink.waitForExistence(timeout: timeout),
                          "question-catalog-link not found", file: file, line: line)
            catalogLink.tap()
        }
    }

    /// Opens Insights. iPhone: Settings → Insights. iPad: the shell's Insights
    /// pane (full-width detail — no sidebar). After it returns, the Insights
    /// content (`insights-empty-state` / `insight-card` / `correlation-*`) is
    /// reachable on both idioms.
    @MainActor
    func openInsights(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        if isPadShell {
            selectPane("Insights")
        } else {
            openSettings(timeout: timeout, file: file, line: line)
            let link = buttons["insights-link"]
            XCTAssertTrue(link.waitForExistence(timeout: timeout),
                          "insights-link not found", file: file, line: line)
            link.tap()
        }
    }
}
