import Foundation
import Observation

/// The large-screen shell's top-level destinations, shared by iPad and Mac
/// (Sprint 3 convergence). Generalizes the Mac-only `MacDetailPane`
/// (`Mac/Sources/MacRootView.swift`), which still exists until a later task
/// replaces it.
public enum AppPane: String, CaseIterable, Identifiable, Sendable {
    case dashboard, insights, questions, groups, catalog

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .insights: "Insights"
        case .questions: "Questions"
        case .groups: "Groups"
        case .catalog: "Catalog"
        }
    }

    /// Setup surfaces vs. review surfaces (dashboard/insights).
    public var isManagement: Bool {
        switch self {
        case .dashboard, .insights: false
        case .questions, .groups, .catalog: true
        }
    }

    /// The reports list is only meaningful on the dashboard; every other pane
    /// shows its own list (or none), so the reports sidebar hides off it.
    public var showsReportsSidebar: Bool { self == .dashboard }
}

/// Shared large-screen navigation state (generalizes the Mac-only
/// `MacNavigation`). Owns the active pane and a per-pane selection so both the
/// iPad picker and the Mac Manage menu drive one source of truth. The shell
/// shows each pane's list in the sidebar and the selected item's
/// detail/editor in the detail column, so the per-pane selection IDs are
/// load-bearing for later tasks, not just Mac's report selection.
@MainActor
@Observable
public final class PaneNavigation {
    public var pane: AppPane = .dashboard
    public var selectedReportID: String?
    public var selectedQuestionID: String?
    public var selectedGroupID: String?
    public var selectedCatalogID: String?

    public init() {}

    /// Menu/picker action: show a pane, clearing the report selection when the
    /// destination pane doesn't show the reports sidebar.
    public func show(_ pane: AppPane) {
        if !pane.showsReportsSidebar { selectedReportID = nil }
        self.pane = pane
    }
}
