import DispatchKit
import SwiftUI

/// Plan 36 / Task 3.5: the Mac navigation root. As of the iPad/Mac UI
/// convergence the Mac renders the shared `LargeScreenShell` (its first
/// adopter) — the reports sidebar (stats header + search) on `.dashboard`,
/// per-pane lists on the management panes, and the selected item's
/// detail/editor on the right, driven by the injected `PaneNavigation`
/// (constructed + injected by `DispatchMacApp`, also driven by the Manage
/// menu). This view now only layers the Mac's File-menu import/export alert
/// over the shell; all pane/selection/search state moved into the shell and
/// `PaneNavigation`.
struct MacRootView: View {
    @Environment(MacExportController.self) private var exportController

    var body: some View {
        LargeScreenShell()
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
}
