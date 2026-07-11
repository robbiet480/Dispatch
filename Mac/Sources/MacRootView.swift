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
    @State private var selectedReportID: String?
    @State private var detailPane: MacDetailPane = .dashboard
    // Owned here (not by the sidebar) so the dashboard sees the same search
    // the sidebar list and stat tiles do — a search that filters "2 reports"
    // must not leave the charts aggregating all 45.
    @State private var searchQuery = ""

    var body: some View {
        NavigationSplitView {
            MacReportsListView(selection: $selectedReportID, searchQuery: $searchQuery)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detailContent
                .toolbar {
                    // Dashboard ↔ Insights switch lives on the detail pane;
                    // hidden while reading a report (Back returns to it).
                    if selectedReportID == nil {
                        ToolbarItem(placement: .principal) {
                            Picker("View", selection: $detailPane) {
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
        // Clear a dangling selection when the selected report disappears
        // (delete, delete-all, remote sync) — plan 27's lesson, same trigger.
        .onChange(of: reports.count) {
            guard let selectedReportID else { return }
            if !reports.contains(where: { $0.uniqueIdentifier == selectedReportID }) {
                self.selectedReportID = nil
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
        if let selectedReportID {
            // Look the report up fresh every render: a row deleted from the
            // sidebar (or a remote-sync delete) must not leave a dangling
            // @Model on screen.
            if let report = reports.first(where: { $0.uniqueIdentifier == selectedReportID }) {
                MacReportDetailView(report: report) {
                    self.selectedReportID = nil
                }
            } else {
                missingReportPlaceholder
            }
        } else {
            switch detailPane {
            case .dashboard: MacDashboardView(searchQuery: searchQuery)
            case .insights: MacInsightsView()
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

enum MacDetailPane: String, CaseIterable, Identifiable {
    case dashboard, insights

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .insights: "Insights"
        }
    }
}
