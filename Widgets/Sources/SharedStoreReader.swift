import DispatchKit
import Foundation
import os
import SwiftData
import WidgetKit

let widgetLog = Logger(subsystem: "io.robbie.Dispatch", category: "widgets")

/// Read-only access to the shared SwiftData store in the App Group container
/// (plan 14 amendment: widgets query the store directly). The widget process
/// NEVER writes and NEVER attaches CloudKit mirroring — `allowsSave: false`,
/// `cloudKitDatabase: .none`; only the app process mirrors. The app pokes
/// `WidgetCenter.reloadAllTimelines()` on report save + replan, so a fresh
/// timeline request is the only signal this reader needs.
enum SharedStoreReader {
    /// Key the app writes (App Group defaults) with the next planned prompt
    /// fire date after each replan; nil/absent when nothing is scheduled.
    static let nextPromptDateKey = "widget.nextPromptDate"

    /// Fetches reports from the shared store and reduces them via the kit's
    /// pure `WidgetSnapshot.compute`. Returns nil when the shared store does
    /// not exist yet (app never launched post-migration, or the migration
    /// fell back to the legacy sandbox URL) — the widget shows a placeholder.
    ///
    /// KNOWN RACE (accepted, see `StoreLocation.migrate`): this
    /// `fileExists` check can land in the tiny window between the app moving
    /// the main store and its sidecars during the one-time migration. Worst
    /// case the read-only open fails or reads a store missing its WAL tail —
    /// the widget renders its placeholder for one timeline cycle and the
    /// next reload (the app pokes on every save/replan/foreground) is
    /// correct; the app-side migration rollback/fail-forward guarantees no
    /// persistent split state.
    static func snapshot(now: Date = Date()) -> WidgetSnapshot? {
        guard let storeURL = StoreLocation.appGroupURL(),
              FileManager.default.fileExists(atPath: storeURL.path) else {
            widgetLog.info("no shared store — placeholder entry")
            return nil
        }
        do {
            let schema = Schema(DispatchStore.allModels)
            let config = ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: false, cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let reports = try context.fetch(FetchDescriptor<Report>())
            let nextPrompt = UserDefaults(suiteName: StoreLocation.appGroupID)?
                .object(forKey: nextPromptDateKey) as? Date
            return WidgetSnapshot.compute(reports: reports, nextPromptDate: nextPrompt, now: now)
        } catch {
            widgetLog.error("shared store read failed: \(error, privacy: .public)")
            return nil
        }
    }
}
