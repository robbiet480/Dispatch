import DispatchKit
import SwiftData
import SwiftUI

/// Plan 36: the Mac navigation root — the shipped iPad split topology
/// (PR #30) rebuilt Mac-native per the owner's design direction: reports
/// sidebar (stats header + search) on the left, dashboard or report detail
/// on the right, with a real sidebar toggle and system menu bar.
struct MacRootView: View {
    @Query private var reports: [Report]
    @Environment(ThemeStore.self) private var themeStore
    @Environment(MacExportController.self) private var exportController
    @Environment(MacNavigation.self) private var navigation
    // Owned here (not by the sidebar) so the dashboard sees the same search
    // the sidebar list and stat tiles do — a search that filters "2 reports"
    // must not leave the charts aggregating all 45.
    @State private var searchQuery = ""

    var body: some View {
        // Pane + report selection live in the shared MacNavigation model so the
        // Manage menu (plan 47) can drive them; @Bindable exposes bindings.
        @Bindable var navigation = navigation
        return NavigationSplitView {
            MacReportsListView(selection: $navigation.selectedReportID, searchQuery: $searchQuery)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detailContent
                .toolbar {
                    // Dashboard ↔ Insights ↔ management switch lives on the
                    // detail pane; hidden while reading a report.
                    if navigation.selectedReportID == nil {
                        ToolbarItem(placement: .principal) {
                            Picker("View", selection: $navigation.pane) {
                                ForEach(MacDetailPane.allCases) { pane in
                                    Text(pane.label).tag(pane)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("detail-pane-picker")
                        }
                    }
                }
        }
        // Switching to a management pane clears any report selection so the
        // detail pane isn't ambiguous (a report would otherwise win the switch
        // below). Plan 47.
        .onChange(of: navigation.pane) {
            if navigation.pane.isManagement { navigation.selectedReportID = nil }
        }
        // Clear a dangling selection when the selected report disappears
        // (delete, delete-all, remote sync) — plan 27's lesson, same trigger.
        .onChange(of: reports.count) {
            guard let selectedReportID = navigation.selectedReportID else { return }
            if !reports.contains(where: { $0.uniqueIdentifier == selectedReportID }) {
                navigation.selectedReportID = nil
            }
        }
        // Import/export results from the File menu land here (the main
        // window); the Settings scene carries its own copy of this alert.
        .alert("Dispatch", isPresented: Binding(
            get: { exportController.isShowingMessage },
            set: { exportController.isShowingMessage = $0 }
        ), presenting: exportController.message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedReportID = navigation.selectedReportID {
            // Look the report up fresh every render: a row deleted from the
            // sidebar (or a remote-sync delete) must not leave a dangling
            // @Model on screen.
            if let report = reports.first(where: { $0.uniqueIdentifier == selectedReportID }) {
                MacReportDetailView(report: report) {
                    navigation.selectedReportID = nil
                }
            } else {
                missingReportPlaceholder
            }
        } else {
            switch navigation.pane {
            case .dashboard: MacDashboardView(searchQuery: searchQuery)
            // Insights, Questions and Groups push-navigate
            // (NavigationLink(destination:)) into per-question correlation /
            // editor screens; the detail column of a NavigationSplitView has no
            // NavigationStack of its own, so those pushes are inert without one
            // wrapped here. Task 2.4 retired the Mac-only MacPromptGroupsView for
            // the shared PromptGroupsView, whose rows/add push the group editor —
            // hence Groups now needs the wrap too. (Catalog wraps itself.)
            case .insights: NavigationStack { InsightsView() }
            case .questions: NavigationStack { QuestionSettingsView() }
            case .groups: NavigationStack { PromptGroupsView() }
            case .catalog: CatalogView()
            }
        }
    }

    private var missingReportPlaceholder: some View {
        ZStack {
            Color.themeBackground(themeStore.theme)
                .ignoresSafeArea()
            Text("Report deleted")
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Shared Mac navigation state (plan 47): the detail pane and the selected
/// report, owned by the app so both `MacRootView` and the `Manage` menu drive
/// the same selection.
@MainActor
@Observable
final class MacNavigation {
    var pane: MacDetailPane = .dashboard
    var selectedReportID: String?

    /// Menu action: show a management pane (clears any report selection so the
    /// pane is what's on screen).
    func show(_ pane: MacDetailPane) {
        selectedReportID = nil
        self.pane = pane
    }
}

enum MacDetailPane: String, CaseIterable, Identifiable {
    case dashboard, insights, questions, groups, catalog

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .insights: "Insights"
        case .questions: "Questions"
        case .groups: "Groups"
        case .catalog: "Catalog"
        }
    }

    /// Setup surfaces (plan 47) — as opposed to the review surfaces
    /// (dashboard/insights). Selecting one clears the report selection.
    var isManagement: Bool {
        switch self {
        case .dashboard, .insights: false
        case .questions, .groups, .catalog: true
        }
    }
}
