import DispatchKit
import SwiftData
import SwiftUI

/// Task 3.4 (iPad/Mac UI convergence): the shared side-by-side split shell that
/// BOTH iPad and Mac adopt (in Tasks 3.5/3.6). One `NavigationSplitView` whose
/// **sidebar swaps by pane** and whose **detail is driven by the pane's
/// selection** — the side-by-side layout the owner chose (list on the left, the
/// selected item's detail/editor on the right).
///
/// It generalizes the Mac-only `MacRootView` topology (reports sidebar + a
/// pane picker over dashboard/insights/questions/groups/catalog) into one
/// dual-target view. `PaneNavigation` (the shared, injectable navigation model)
/// is READ from the environment — the adopters construct and inject it; the
/// shell never owns it. This task only CREATES the view and makes both targets
/// compile with it; it does NOT yet replace `MacRootView`/`RootNavigationView`
/// (that's 3.5/3.6), so it is unused at the end of this task.
///
/// Structure:
/// - The **sidebar** is the pane's list: the reports list on `.dashboard` (the
///   one pane that shows the reports sidebar), nothing on `.insights`
///   (full-width — see `syncColumnVisibility()`), and the pure
///   `QuestionsList`/`GroupsList`/`CatalogListView` on the management panes.
/// - The **detail** renders the current selection: a report detail or the
///   dashboard on `.dashboard`, Insights full-width, and — on the management
///   panes — the selected item's editor keyed with `.id(...)` so switching the
///   selection makes a FRESH editor bound to the new item.
/// - The principal-toolbar pane `Picker` is the SOLE window title: the shell
///   sets no `navigationTitle` of its own, and its hosted detail views
///   suppress theirs via `.environment(\.isInLargeScreenShell, true)` (Task
///   3.8, `ShellContext.swift`) — set here on the detail column only, never
///   the sidebar. The picker's setter routes through `nav.show(_:)` so
///   selection-clearing happens in one place.
///
/// Platform seams: the reports list/detail are `#if os` (the Mac twins live in
/// `Mac/Sources`, the iOS originals lean on UIKit/nav-bar chrome); the iOS-only
/// Settings gear presents `SettingsView` as a sheet. The reports sidebar
/// (`ReportsListView`/`MacReportsListView`) owns the shell's ONE `.searchable`
/// — never add a second LIVE `.searchable` to another column while it's
/// showing; two live `.searchable` in the same split view crashes AppKit.
struct LargeScreenShell: View {
    // Injected by the adopters (3.5/3.6) — never constructed here.
    @Environment(PaneNavigation.self) private var nav
    @Environment(ThemeStore.self) private var themeStore

    // Selections resolve against these live queries (a row can outlive its
    // model — deleted while selected — so every lookup is guarded).
    @Query private var reports: [Report]
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query(sort: \PromptGroup.sortOrder) private var groups: [PromptGroup]

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The reports sidebar's search query (macOS only — the Mac reports list
    /// owns the search field). iOS's `ReportsListView` carries its own internal
    /// search, so this stays "" there.
    @State private var reportsSearch = ""
    @State private var catalogStore = CatalogStore()
    @State private var showingCatalogSubmit = false

    // "New" editor targets: an empty editor in the detail column. Set by the
    // list's onAdd closure (which also clears the id selection); cleared when a
    // row is selected (see `questionSelection`/`groupSelection`) or the pane
    // changes (`resetComposing()`). Composing and a row selection are mutually
    // exclusive.
    @State private var composingQuestion = false
    @State private var composingGroup = false

    #if os(iOS)
    @State private var showingSettings = false
    #endif

    private var theme: Theme { themeStore.theme }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .toolbar { paneToolbar }
                // Task 3.8: tells the hosted detail views (Dashboard/Catalog/
                // Insights/Question editor/Group editor/Report detail) to
                // suppress their own `navigationTitle` — the pane picker
                // above is the sole title here. Sidebar gets none: it sets no
                // titles of its own (the reports column's "Reports" title is
                // legitimate sidebar chrome, not a duplicate).
                .environment(\.isInLargeScreenShell, true)
        }
        // Pane change: a "new" editor never survives leaving its pane, and
        // Insights collapses the sidebar to go full-width. `initial: true`
        // seeds the correct column visibility on first appearance.
        .onChange(of: nav.pane, initial: true) {
            resetComposing()
            syncColumnVisibility()
        }
        // Auto-select the first catalog entry once the list loads so the detail
        // column isn't blank at regular width (optional nicety) — only when on
        // the catalog pane with nothing chosen.
        .onChange(of: firstCatalogID) { _, newValue in
            if nav.pane == .catalog, nav.selectedCatalogID == nil, let newValue {
                nav.selectedCatalogID = newValue
            }
        }
        // Fix wave 1: a search/filter change can drop the selected entry out
        // of `filteredEntries` entirely (not just change which is first),
        // leaving the detail column stuck on an empty state while the list is
        // populated — auto-select-first above only fires when the selection
        // is nil. Reconcile here: if the current selection is no longer in
        // the filtered list, clear it so the auto-select-first path re-fires.
        .onChange(of: catalogStore.filteredEntries) { _, entries in
            if let selected = nav.selectedCatalogID,
               !entries.contains(where: { $0.id == selected }) {
                nav.selectedCatalogID = nil
            }
        }
        .sheet(isPresented: $showingCatalogSubmit) {
            CatalogSubmitView(store: catalogStore)
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
    }

    // MARK: - Toolbar (the sole title)

    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        // The pane picker IS the window title (no `navigationTitle` on the
        // shell). Its setter routes through `nav.show(_:)` so the report
        // selection is cleared in one place when leaving the dashboard.
        ToolbarItem(placement: .principal) {
            Picker("View", selection: paneBinding) {
                ForEach(AppPane.allCases) { pane in
                    Text(pane.label).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("shell-pane-picker")
        }
        #if os(iOS)
        // Settings has no split-view home on iOS/iPad — it stays a modal sheet
        // reached from a trailing gear (the Mac keeps it in the app menu).
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("shell-settings-button")
        }
        #endif
    }

    private var paneBinding: Binding<AppPane> {
        Binding(get: { nav.pane }, set: { nav.show($0) })
    }

    // MARK: - Sidebar (swaps by pane)

    @ViewBuilder
    private var sidebar: some View {
        switch nav.pane {
        case .dashboard:
            // The ONE pane that shows the reports sidebar.
            #if os(macOS)
            MacReportsListView(selection: reportSelection, searchQuery: $reportsSearch)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            #else
            ReportsListView(selection: reportSelection)
            #endif
        case .insights:
            // No sidebar — Insights is full-width (columnVisibility → .detailOnly).
            EmptyView()
        case .questions:
            QuestionsList(
                selection: questionSelection,
                onAddQuestion: { startComposingQuestion() },
                onOpenCatalog: { nav.show(.catalog) }
            )
        case .groups:
            GroupsList(
                selection: groupSelection,
                onAddGroup: { startComposingGroup() }
            )
        case .catalog:
            CatalogListView(
                store: catalogStore,
                selection: catalogSelection,
                onSubmit: { showingCatalogSubmit = true }
            )
        }
    }

    // MARK: - Detail (pane + selection → content)

    @ViewBuilder
    private var detail: some View {
        switch nav.pane {
        case .dashboard:
            dashboardDetail
        case .insights:
            // Full-width; the correlation drill-in pushes inside this stack.
            NavigationStack { InsightsView() }
        case .questions:
            // Wrapped so the editor's inner pushes (the choice-options editor)
            // work in the detail column.
            NavigationStack { questionDetail }
        case .groups:
            NavigationStack { groupDetail }
        case .catalog:
            catalogDetail
        }
    }

    @ViewBuilder
    private var dashboardDetail: some View {
        // Look the report up fresh every render: a row deleted from the sidebar
        // (or a remote-sync delete) must not leave a dangling @Model on screen.
        if let id = nav.selectedReportID,
           let report = reports.first(where: { $0.uniqueIdentifier == id }) {
            #if os(macOS)
            MacReportDetailView(report: report) { nav.selectedReportID = nil }
            #else
            ReportDetailView(report: report)
            #endif
        } else {
            dashboardContent
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        #if os(macOS)
        // MacDashboardView wraps DashboardContentView with the Mac chrome the
        // shell must NOT drop: the `#if os(macOS)` filter bar / `MacFilterPopover`
        // (via DashboardContentView), the Mac-native `home-hexagon` empty state,
        // and the "N reports" count — all keyed to the same `reportsSearch` the
        // reports sidebar owns. It handles its own empty state, so don't gate on
        // `reports.isEmpty` here (that would double up the empty view).
        MacDashboardView(searchQuery: reportsSearch)
        #else
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            // DashboardContentView assumes a non-empty report set (the two empty
            // states stay with the callers), so the shell owns the empty state.
            if reports.isEmpty {
                emptyStateLabel(
                    title: "No reports yet",
                    message: "File reports on your iPhone or Apple Watch — they sync here through iCloud."
                )
            } else {
                DashboardContentView(
                    searchQuery: reportsSearch,
                    // Adaptive columns reflow on window/split resize (the Mac
                    // dashboard's grid). The compact pager is unused at the
                    // regular widths this shell targets.
                    columns: [GridItem(.adaptive(minimum: 340), spacing: 16)],
                    selectedQuestionID: .constant(nil)
                )
            }
        }
        #endif
    }

    @ViewBuilder
    private var questionDetail: some View {
        if composingQuestion {
            // `.id("new")` keeps the empty editor distinct from any selected
            // question's editor. This "new" editor is the detail column's
            // NavigationStack ROOT, so its `\.dismiss` is a no-op — `onSaved`
            // clears `composingQuestion` and selects the just-created row
            // instead, which flips `.id` from "new" to the real id and swaps
            // in a fresh edit-existing editor (fix wave 1: without this, Save
            // left the stale "new" editor on screen and a second Save
            // inserted a duplicate question).
            QuestionEditorView(question: nil, onSaved: { id in
                composingQuestion = false
                nav.selectedQuestionID = id
            })
                .id("new")
        } else if let id = nav.selectedQuestionID,
                  let question = questions.first(where: { $0.uniqueIdentifier == id }) {
            // `.id(selection)` so switching rows creates a FRESH editor bound to
            // the new question (otherwise SwiftUI reuses the editor's @State).
            // `onSaved` re-selects the same id here — a harmless no-op that
            // keeps one code path for both the new and existing editors.
            QuestionEditorView(question: question, onSaved: { id in
                composingQuestion = false
                nav.selectedQuestionID = id
            })
                .id(id)
        } else {
            emptyState(title: "Select a question",
                       message: "Choose a question to edit, or add a new one.")
        }
    }

    @ViewBuilder
    private var groupDetail: some View {
        if composingGroup {
            // Same "new"-editor-is-the-stack-root fix as `questionDetail`
            // above: `onSaved` clears `composingGroup` and selects the saved
            // group so `.id` flips from "new" to the real id.
            PromptGroupEditorView(group: nil, onSaved: { id in
                composingGroup = false
                nav.selectedGroupID = id
            })
                .id("new")
        } else if let id = nav.selectedGroupID,
                  let group = groups.first(where: { $0.uniqueIdentifier == id }) {
            // `onSaved` re-selects the same id here — a harmless no-op.
            PromptGroupEditorView(group: group, onSaved: { id in
                composingGroup = false
                nav.selectedGroupID = id
            })
                .id(id)
        } else {
            emptyState(title: "Select a group",
                       message: "Choose a prompt group to edit, or add a new one.")
        }
    }

    @ViewBuilder
    private var catalogDetail: some View {
        if let id = nav.selectedCatalogID,
           let entry = catalogStore.filteredEntries.first(where: { $0.id == id }) {
            CatalogDetailView(entry: entry, store: catalogStore)
        } else {
            emptyState(title: "Select a question",
                       message: "Choose a catalog question to preview and add.")
        }
    }

    // MARK: - Selections (id ⇄ PaneNavigation)

    private var reportSelection: Binding<String?> {
        Binding(get: { nav.selectedReportID }, set: { nav.selectedReportID = $0 })
    }

    /// Selecting a question clears the composing flag — a row selection and a
    /// "new" editor are mutually exclusive.
    private var questionSelection: Binding<String?> {
        Binding(
            get: { nav.selectedQuestionID },
            set: { newValue in
                nav.selectedQuestionID = newValue
                if newValue != nil { composingQuestion = false }
            }
        )
    }

    private var groupSelection: Binding<String?> {
        Binding(
            get: { nav.selectedGroupID },
            set: { newValue in
                nav.selectedGroupID = newValue
                if newValue != nil { composingGroup = false }
            }
        )
    }

    private var catalogSelection: Binding<CatalogQuestion.ID?> {
        Binding(get: { nav.selectedCatalogID }, set: { nav.selectedCatalogID = $0 })
    }

    private var firstCatalogID: CatalogQuestion.ID? {
        catalogStore.filteredEntries.first?.id
    }

    // MARK: - State transitions

    /// The list's onAdd closure: open a "new" editor and clear the id selection
    /// so composing and a row selection can't both be active.
    private func startComposingQuestion() {
        composingQuestion = true
        nav.selectedQuestionID = nil
    }

    private func startComposingGroup() {
        composingGroup = true
        nav.selectedGroupID = nil
    }

    /// A "new" editor never survives leaving its pane.
    private func resetComposing() {
        composingQuestion = false
        composingGroup = false
    }

    /// Insights is full-width (no sidebar); every other pane keeps its list.
    private func syncColumnVisibility() {
        columnVisibility = nav.pane == .insights ? .detailOnly : .automatic
    }

    // MARK: - Empty states (themed)

    private func emptyState(title: String, message: String) -> some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()
            emptyStateLabel(title: title, message: message)
        }
    }

    private func emptyStateLabel(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
