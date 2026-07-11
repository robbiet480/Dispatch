import DispatchKit
import os
import SwiftData
import SwiftUI

private let seedLog = Logger(subsystem: "io.robbie.Dispatch", category: "seed")

/// Plan 36: the Mac-native review shell. Same SwiftData schema, same CloudKit
/// container (`iCloud.io.robbie.Dispatch`) as iOS/watchOS — CloudKit is the
/// sole data channel between platforms. No capture, no sensors, no
/// notifications, no widgets (deliberate v1 non-goals; see the plan doc).
@main
struct DispatchMacApp: App {
    let container: ModelContainer
    let themeStore: ThemeStore
    let visualizationFilterStore: VisualizationFilterStore
    let remoteChangeObserver: RemoteChangeObserver
    private let appDefaults: UserDefaults
    private let isTestEnvironment: Bool

    init() {
        // Same test-isolation contract as iOS: any test-flagged launch gets
        // an isolated, wiped defaults suite and an in-memory, never-CloudKit
        // store. There is no Mac UI-test suite in v1, but the gate keeps a
        // future one from ever touching real data.
        let arguments = ProcessInfo.processInfo.arguments
        isTestEnvironment = arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        if isTestEnvironment,
           let uiTestingDefaults = UserDefaults(suiteName: "ui-testing") {
            uiTestingDefaults.removePersistentDomain(forName: "ui-testing")
            appDefaults = uiTestingDefaults
        } else {
            appDefaults = .standard
        }

        let syncPolicy = SyncPolicy(defaults: appDefaults, isTestEnvironment: isTestEnvironment)
        let (madeContainer, cloudKitActive) = Self.makeContainer(
            syncEnabled: syncPolicy.shouldSync, inMemory: isTestEnvironment
        )
        container = madeContainer

        themeStore = ThemeStore(defaults: appDefaults)
        visualizationFilterStore = VisualizationFilterStore(defaults: appDefaults)

        // Remote-change reactions (shared observer, plan 13/36): dedupe +
        // vocabulary rebuild on CloudKit imports. The Mac app has no
        // notification scheduler, event observers, or Spotlight index —
        // the callback is deliberately a no-op.
        remoteChangeObserver = RemoteChangeObserver(
            container: container,
            defaults: appDefaults,
            isTestEnvironment: isTestEnvironment,
            isSyncActive: cloudKitActive,
            onRemoteChangesApplied: { _ in }
        )

        // Deterministic UUIDv5 defaults (kit-side): a fresh Mac store before
        // the first CloudKit import seeds the SAME question IDs every device
        // seeds, so sync merges rather than duplicates.
        do {
            try DefaultQuestions.seedIfEmpty(into: ModelContext(container))
        } catch {
            seedLog.error("failed to seed default questions: \(error, privacy: .public)")
        }

        remoteChangeObserver.start()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(themeStore)
                .environment(visualizationFilterStore)
                .environment(remoteChangeObserver)
                .environment(\.appDefaults, appDefaults)
                .frame(minWidth: 900, minHeight: 560)
        }
        .modelContainer(container)
    }

    /// Mirror of the iOS container construction with plan 36's DECISION 3:
    /// the Mac store lives in the app's own Application Support (no App
    /// Group — no Mac widgets/intents read it, and macOS app-group container
    /// semantics differ). Never fail launch over sync: CloudKit construction
    /// errors log and fall back to the plain local container; the local path
    /// passes `.none` explicitly so the iCloud entitlements can't re-infer
    /// CloudKit for the sync-disabled path.
    private static func makeContainer(
        syncEnabled: Bool, inMemory: Bool = false
    ) -> (ModelContainer, cloudKitActive: Bool) {
        let schema = Schema(DispatchStore.allModels)
        if inMemory {
            do {
                let config = ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                syncLog.info("in-memory container active (test environment)")
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
                    cloudKitDatabase: .private(SyncPolicy.containerIdentifier)
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                syncLog.info("CloudKit-mirrored container active (\(SyncPolicy.containerIdentifier, privacy: .public))")
                return (container, cloudKitActive: true)
            } catch {
                syncLog.error("CloudKit container construction failed, falling back to local: \(error, privacy: .public)")
            }
        }
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            syncLog.info("local (non-CloudKit) container active")
            return (container, cloudKitActive: false)
        } catch {
            fatalError("failed to open local model container: \(error)")
        }
    }

    /// Application Support/Dispatch.store inside the sandbox container.
    private static func resolveStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "Dispatch.store")
    }
}
