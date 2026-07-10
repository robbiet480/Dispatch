import DispatchKit
import Foundation
import os
import SwiftData

/// One OSLog category for every watch-side sync decision — same story the
/// phone's SyncPolicy/makeContainer tell, readable via
/// `log stream --predicate 'category == "sync"'`.
let watchSyncLog = Logger(subsystem: "io.robbie.Dispatch.watchkitapp", category: "sync")

/// Thin watch-side mirror of the App target's `SyncPolicy` + container
/// construction (App/Sources/Sync/SyncPolicy.swift, DispatchApp.makeContainer).
/// A mirror rather than an extraction: the phone's version is entangled with
/// its one-time legacy→App Group store migration and fatalError semantics,
/// which don't lift cleanly (the watch has no legacy store to migrate).
///
/// Semantics preserved exactly:
/// - user toggle from the WATCH'S OWN defaults (`iCloudSyncEnabled`, absent
///   key = ON) — sensor/sync settings are per-device, nothing syncs them;
/// - test environment (`--ui-testing`/`--mock-sensors`) forces an in-memory
///   local container, CloudKit/ubiquity never touched under test args;
/// - never-fail-launch: CloudKit construction failure logs and falls back to
///   the plain local container (`cloudKitDatabase: .none` explicitly — with
///   the iCloud entitlement present, `.automatic` would infer CloudKit).
///
/// The store lives in the WATCH'S app-group container (shared with the watch
/// widget extension only — App Group containers are per-device and never
/// cross devices: https://developer.apple.com/forums/thread/3927). The watch
/// runs neither RemoteChangeObserver nor SyncDedupe — the phone stays
/// pipeline authority; mirrored changes just arrive.
enum WatchStoreBootstrap {
    /// Mirrors `SyncPolicy.enabledKey` — same key so a future settings UI
    /// reads/writes the same toggle name on both platforms.
    static let syncEnabledKey = "iCloudSyncEnabled"

    static func isTestEnvironment(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("--ui-testing") || arguments.contains("--mock-sensors")
    }

    /// The effective sync decision for this launch, with the same logged
    /// story as the phone's `SyncPolicy.shouldSync`.
    static func shouldSync(defaults: UserDefaults, isTestEnvironment: Bool) -> Bool {
        if isTestEnvironment {
            watchSyncLog.info("sync disabled: test environment (forced local container)")
            return false
        }
        let userPreference = defaults.object(forKey: syncEnabledKey) as? Bool ?? true
        if !userPreference {
            watchSyncLog.info("sync disabled: user toggle off")
            return false
        }
        watchSyncLog.info("sync enabled: user toggle on (or default)")
        return true
    }

    /// Builds the watch's ModelContainer. Same never-fail-launch shape as the
    /// phone's makeContainer; the only structural difference is that there is
    /// no legacy-URL migration (fresh watch installs create the store in the
    /// app-group container directly, falling back to the sandbox default
    /// location if the group container is unavailable — misprovisioned build).
    static func makeContainer(
        syncEnabled: Bool, inMemory: Bool = false
    ) -> (ModelContainer, cloudKitActive: Bool) {
        let schema = Schema(DispatchStore.allModels)
        if inMemory {
            do {
                let config = ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                watchSyncLog.info("in-memory container active (test environment)")
                return (container, cloudKitActive: false)
            } catch {
                fatalError("failed to open in-memory model container: \(error)")
            }
        }
        let storeURL = resolveStoreURL()
        if syncEnabled {
            do {
                let config = ModelConfiguration(
                    schema: schema, url: storeURL,
                    cloudKitDatabase: .private(WatchStoreBootstrap.cloudKitContainerIdentifier)
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                watchSyncLog.info("CloudKit-mirrored container active (\(Self.cloudKitContainerIdentifier, privacy: .public))")
                return (container, cloudKitActive: true)
            } catch {
                watchSyncLog.error("CloudKit container construction failed, falling back to local: \(error, privacy: .public)")
            }
        }
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            watchSyncLog.info("local (non-CloudKit) container active")
            return (container, cloudKitActive: false)
        } catch {
            fatalError("failed to open local model container: \(error)")
        }
    }

    /// Mirrors `SyncPolicy.containerIdentifier` — the same private CloudKit
    /// container the phone mirrors; that identity IS the sync fabric.
    static let cloudKitContainerIdentifier = "iCloud.io.robbie.Dispatch"

    /// The watch store lives in the watch's app-group container so the watch
    /// widget extension (complications) can read it — the same architecture
    /// as the phone widgets, one device over. Falls back to the sandbox
    /// default location when the group container is unavailable (the watch
    /// widgets then render their placeholder; the app runs fine).
    ///
    /// Naming note: `StoreLocation.legacyURL()` is "legacy" only in the
    /// PHONE'S history (the pre-plan-14 store path a phone install migrates
    /// away from). On the watch there is no legacy store and no migration —
    /// the function is reused purely as "the sandbox Application Support
    /// default store URL", the never-fail-launch fallback for a
    /// misprovisioned build without the App Group entitlement.
    private static func resolveStoreURL() -> URL {
        if let groupURL = StoreLocation.appGroupURL() {
            return groupURL
        }
        watchSyncLog.error("APP GROUP CONTAINER UNAVAILABLE — running from sandbox store URL")
        return StoreLocation.legacyURL()
    }
}
