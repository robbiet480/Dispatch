import Foundation
import WidgetKit

/// Pokes the watch complication timelines after a save/foreground — the
/// watch widget extension reads the shared store directly and gets no
/// change notifications (same architecture as the phone's WidgetRefresher).
/// Test-gated like every widget poke in the project.
enum WatchWidgetRefresher {
    static func reload() {
        guard !WatchStoreBootstrap.isTestEnvironment() else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
