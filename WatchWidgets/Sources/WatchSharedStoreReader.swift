import DispatchKit
import Foundation
import os
import SwiftData

let watchWidgetLog = Logger(subsystem: "io.robbie.Dispatch.watchkitapp.widgets", category: "widgets")

/// Read-only access to the WATCH'S shared SwiftData store in the watch's
/// app-group container — the exact mirror of the phone's SharedStoreReader,
/// one device over (App Group containers are per-device; this never sees
/// phone data except through CloudKit into the watch app's store). The
/// widget process NEVER writes and NEVER attaches CloudKit mirroring —
/// `allowsSave: false`, `cloudKitDatabase: .none`; only the watch app
/// mirrors. The watch app pokes reloadAllTimelines on save/foreground.
///
/// Deliberately unlike the phone reader: NO `nextPromptDate` read.
/// `WidgetSnapshot.nextPromptDate` is a planner pass-through fed via the
/// PHONE'S app-group defaults; with no watch-local scheduling and no
/// defaults sync it is always nil here, and watch complication layouts
/// must not reserve space for it (plan 19 design §v1-scope-4).
enum WatchSharedStoreReader {
    /// Returns nil when the shared store does not exist yet (watch app
    /// never launched, or the group container was unavailable and the app
    /// fell back to its sandbox URL) — the complication shows a placeholder.
    static func snapshot(now: Date = Date()) -> WidgetSnapshot? {
        guard let storeURL = StoreLocation.appGroupURL(),
              FileManager.default.fileExists(atPath: storeURL.path) else {
            watchWidgetLog.info("no shared store — placeholder entry")
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
            return WidgetSnapshot.compute(reports: reports, nextPromptDate: nil, now: now)
        } catch {
            watchWidgetLog.error("shared store read failed: \(error, privacy: .public)")
            return nil
        }
    }
}
