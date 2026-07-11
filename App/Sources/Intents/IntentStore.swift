import DispatchKit
import Foundation
import os
import SwiftData

private let intentStoreLog = Logger(subsystem: "io.robbie.Dispatch", category: "intent-store")

/// Shared SwiftData access for the App Intents layer (plan 49). App Intents
/// are instantiated by the system (Shortcuts, Siri, Spotlight) — often in a
/// background-launched process while the foreground app has the store open —
/// so entity/query intents open the SHARED App Group store READ-ONLY
/// (`allowsSave: false`, `cloudKitDatabase: .none`) exactly like the widget
/// `SharedStoreReader` / `PromptGroupQuery`. The write path (`LogAnswerIntent`)
/// opens it WRITABLE, matching the probe-verified `QuickAnswerIntent` contract:
/// only the app process mirrors to CloudKit; a row filed here is ingested by
/// the app's history tracking at next launch/foreground.
enum IntentStore {
    private static func container(allowsSave: Bool) -> ModelContainer? {
        guard let storeURL = StoreLocation.appGroupURL(),
              FileManager.default.fileExists(atPath: storeURL.path) else {
            intentStoreLog.info("no shared store (fresh install / misprovisioned build)")
            return nil
        }
        do {
            let schema = Schema(DispatchStore.allModels)
            let config = ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: allowsSave, cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            intentStoreLog.error("shared store open failed (allowsSave=\(allowsSave, privacy: .public)): \(error, privacy: .public)")
            return nil
        }
    }

    /// A read-only context for query/entity intents. nil when the store is
    /// unavailable — callers degrade to empty results / a "not ready" dialog
    /// rather than throwing in the Shortcuts UI.
    static func readOnlyContext() -> ModelContext? {
        container(allowsSave: false).map(ModelContext.init)
    }

    /// A writable context for the log-answer intent. nil when the store is
    /// unavailable.
    static func writableContext() -> ModelContext? {
        container(allowsSave: true).map(ModelContext.init)
    }

    /// All non-draft reports (with their responses) for the query intents.
    static func allReports() -> [Report] {
        guard let context = readOnlyContext() else { return [] }
        let descriptor = FetchDescriptor<Report>(predicate: #Predicate { !$0.isDraft })
        return (try? context.fetch(descriptor)) ?? []
    }
}
