import DispatchKit
import SwiftUI

/// The app's navigation root, chosen once per launch by idiom.
///
/// iPhone keeps the existing stacked topology (`HomeView` owns its
/// `NavigationStack`). iPad adopts the shared `LargeScreenShell` (Task 3.6 of
/// the iPad/Mac UI convergence) — the top pane picker + side-by-side panes,
/// the same shell the Mac uses (Task 3.5). The topology gate is the *idiom*
/// (not the horizontal size class) on purpose: swapping shell ↔ stack roots on
/// a size-class change (Split View/Slide Over) would discard navigation state
/// mid-scene. The shell's own `NavigationSplitView` collapses to stacked
/// behavior at compact widths, which is why it must be the root here rather
/// than a push destination (pushed split views collapse unconditionally).
///
/// The shell reads `PaneNavigation` from `@Environment` and traps if absent, so
/// this view constructs and injects it. Everything else the shell + its panes
/// need (`ThemeStore`, `modelContext`, `appDefaults`, …) is already in the
/// ambient environment `DispatchApp` installs above this root — only
/// `PaneNavigation` is net-new here. The `@State` is created for both idioms
/// but only used on iPad (cheap).
struct RootNavigationView: View {
    @State private var paneNavigation = PaneNavigation()

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            LargeScreenShell()
                .environment(paneNavigation)
        } else {
            HomeView()
        }
    }
}
