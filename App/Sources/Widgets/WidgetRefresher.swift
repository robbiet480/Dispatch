import DispatchKit
import Foundation
import WidgetKit

/// The app-side half of the widget contract: widgets read the shared App
/// Group store directly, but extensions get no change notifications — so the
/// app pokes `WidgetCenter.reloadAllTimelines()` whenever the data a widget
/// renders could have changed (report save, replan, foregrounding). Replans
/// also publish the next planned prompt fire date to App Group defaults
/// (the widget can't see UNUserNotificationCenter's pending requests).
enum WidgetRefresher {
    /// Shared-defaults key for the next planned prompt fire date. Must match
    /// `SharedStoreReader.nextPromptDateKey` in the widget extension.
    static let nextPromptDateKey = "widget.nextPromptDate"

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Called at the end of every replan: records the earliest planned
    /// prompt (nil clears it — asleep or nothing scheduled), then reloads.
    static func replanCompleted(nextPromptDate: Date?) {
        let defaults = UserDefaults(suiteName: StoreLocation.appGroupID)
        if let nextPromptDate {
            defaults?.set(nextPromptDate, forKey: nextPromptDateKey)
        } else {
            defaults?.removeObject(forKey: nextPromptDateKey)
        }
        reload()
    }
}
