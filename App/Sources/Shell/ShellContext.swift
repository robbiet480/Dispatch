import SwiftUI

/// Task 3.8 (iPad/Mac UI convergence): a shell-context flag so the SIX detail
/// views `LargeScreenShell` hosts (`MacDashboardView`, `CatalogDetailView`,
/// `InsightsView`, `QuestionEditorView`, `PromptGroupEditorView`,
/// `MacReportDetailView`) can suppress their own `navigationTitle` ONLY when
/// rendered inside the shell — where the principal-toolbar pane `Picker` is
/// the sole title (Task 3.4/3.7) and a second title would surface as a
/// duplicate window title next to it. Those same views are ALSO pushed from
/// iPhone Settings (`QuestionSettingsView`/`PromptGroupsView`/`CatalogView`),
/// where the title IS wanted — the default `false` here preserves that path
/// untouched; `LargeScreenShell` is the only place that flips it to `true`. It
/// sets the flag on BOTH split columns: the detail column reads it for title
/// suppression (above), and the sidebar carries it too so `QuestionsList` hides
/// its redundant "QUESTION CATALOG…" row on iPad/Mac (sidebar list titles stay
/// unconditional, so title suppression there is unaffected).
private struct IsInLargeScreenShellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isInLargeScreenShell: Bool {
        get { self[IsInLargeScreenShellKey.self] }
        set { self[IsInLargeScreenShellKey.self] = newValue }
    }
}
