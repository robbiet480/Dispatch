import DispatchKit
import SwiftData
import SwiftUI

/// Plan 27: the app's navigation root, chosen once per launch by idiom.
///
/// iPhone keeps the existing stacked topology (`HomeView` owns its
/// `NavigationStack`). iPad gets a `NavigationSplitView` — reports list as
/// the sidebar, Home dashboard / report detail in the detail column. The
/// topology gate is the *idiom* (not the horizontal size class) on purpose:
/// swapping split ↔ stack roots on a size-class change (Split View/Slide
/// Over) would discard navigation state mid-scene. A `NavigationSplitView`
/// collapses to stacked behavior on its own at compact widths, which is why
/// it must be the root here rather than a push destination (pushed split
/// views collapse unconditionally).
struct RootNavigationView: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            PadRootView()
        } else {
            HomeView()
        }
    }
}

private struct PadRootView: View {
    @Query private var reports: [Report]
    @Environment(ThemeStore.self) private var themeStore
    @State private var selectedReportID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Selecting a sidebar row maps to a one-deep detail path so the report
    /// detail gets a system back button and the dashboard is always the
    /// detail root (back button pops → selection clears via the setter).
    private var detailPath: Binding<[String]> {
        Binding(
            get: { selectedReportID.map { [$0] } ?? [] },
            set: { selectedReportID = $0.last }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ReportsListView(selection: $selectedReportID)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            NavigationStack(path: detailPath) {
                HomeView(isEmbedded: true, toggleSidebar: toggleSidebar)
                    .navigationDestination(for: String.self) { reportID in
                        // Look the report up fresh: a row deleted from the
                        // sidebar (or a remote-sync delete) must not leave a
                        // dangling @Model on screen.
                        if let report = reports.first(where: { $0.uniqueIdentifier == reportID }) {
                            ReportDetailView(report: report)
                        } else {
                            missingReportPlaceholder
                        }
                    }
            }
        }
        // Clear a dangling selection when the selected report disappears
        // (swipe-delete in the sidebar, delete-all, remote sync). Count is a
        // sufficient trigger even though a same-count delete+insert wouldn't
        // fire it: the detail destination re-resolves by ID on every render,
        // so that edge benignly lands on the deleted-report placeholder.
        .onChange(of: reports.count) {
            guard let selectedReportID else { return }
            if !reports.contains(where: { $0.uniqueIdentifier == selectedReportID }) {
                self.selectedReportID = nil
            }
        }
    }

    private func toggleSidebar() {
        // The Home dashboard hides its navigation bar, so the system's own
        // sidebar toggle isn't visible there — the dashboard's list button
        // (same `reports-list-button` identifier as the iPhone push link)
        // drives column visibility instead.
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
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
