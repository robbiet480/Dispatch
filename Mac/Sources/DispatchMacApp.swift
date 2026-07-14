import AppKit
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
    let exportController: MacExportController
    @State private var navigation = PaneNavigation()
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
        // Screenshot rig: `--theme <name>` pins the launch theme so each App
        // Store shot can use a different palette color — same test-gated
        // contract as DispatchApp.
        if isTestEnvironment,
           let flagIndex = arguments.firstIndex(of: "--theme"),
           arguments.indices.contains(flagIndex + 1),
           let forced = Theme(rawValue: arguments[flagIndex + 1]) {
            themeStore.theme = forced
        }
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

        exportController = MacExportController(container: container)

        // Deterministic UUIDv5 defaults (kit-side): a fresh Mac store before
        // the first CloudKit import seeds the SAME question IDs every device
        // seeds, so sync merges rather than duplicates.
        do {
            try DefaultQuestions.seedIfEmpty(into: ModelContext(container))
        } catch {
            seedLog.error("failed to seed default questions: \(error, privacy: .public)")
        }

        // Screenshot fixture (same contract as DispatchApp): only reachable
        // from the test environment's in-memory store, so the seeded demo
        // reports can never touch (or sync) real iCloud data.
        if isTestEnvironment, arguments.contains("--demo-data") {
            do {
                try DemoData.seed(into: ModelContext(container))
            } catch {
                seedLog.error("demo-data seeding failed: \(error, privacy: .public)")
            }
        }

        remoteChangeObserver.start()
    }

    /// Screenshot rig: `--screenshot-window` (test-gated) pins the main
    /// window to a 1440x900-point frame — 16:10, which lands on an
    /// ASC-accepted Mac screenshot pixel size at both 1x (1440x900) and
    /// 2x/Retina (2880x1800). Runs async so the window exists.
    private func pinScreenshotWindowIfRequested() {
        guard isTestEnvironment,
              ProcessInfo.processInfo.arguments.contains("--screenshot-window") else { return }
        // The window may not exist yet when the root view first appears —
        // retry over ~5s until it does.
        pinScreenshotWindow(attemptsLeft: 25)
    }

    private func pinScreenshotWindow(attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
                if attemptsLeft > 0 { pinScreenshotWindow(attemptsLeft: attemptsLeft - 1) }
                return
            }
            var frame = window.frame
            frame.size = NSSize(width: 1440, height: 900)
            window.setFrame(frame, display: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(themeStore)
                .environment(visualizationFilterStore)
                .environment(remoteChangeObserver)
                .environment(exportController)
                .environment(navigation)
                .environment(\.appDefaults, appDefaults)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { pinScreenshotWindowIfRequested() }
        }
        .modelContainer(container)
        // File → Import…/Export (plan 36 DECISION 6). Everything routes
        // through MacExportController's user-driven panels; results surface
        // in MacRootView's alert. ⌘F (search) lives in the sidebar; ⌘,
        // (Settings) is system-provided by the Settings scene below.
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import Reporter/Dispatch JSON…") {
                    exportController.importJSON()
                }
                .keyboardShortcut("i", modifiers: .command)
                Menu("Export") {
                    Button("Day One JSON…") { exportController.exportDayOne() }
                    Button("Markdown Folder…") { exportController.exportMarkdown() }
                    Divider()
                    Button("Dispatch JSON…") { exportController.exportDispatchJSON() }
                    Button("CSV…") { exportController.exportCSV() }
                    Divider()
                    Button("Questions (JSON)…") { exportController.exportQuestionsJSON() }
                    Button("Questions (CSV)…") { exportController.exportQuestionsCSV() }
                }
            }
            // Plan 47: the Manage menu drives the shared navigation model so
            // the setup surfaces are reachable by keyboard, not only the
            // segmented picker.
            CommandMenu("Manage") {
                Button("Dashboard") { navigation.show(.dashboard) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Insights") { navigation.show(.insights) }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Questions") { navigation.show(.questions) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Prompt Groups") { navigation.show(.groups) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Question Catalog") { navigation.show(.catalog) }
                    .keyboardShortcut("5", modifiers: .command)
            }
        }

        Settings {
            MacSettingsView()
                .environment(themeStore)
                .environment(remoteChangeObserver)
                .environment(exportController)
                .environment(\.appDefaults, appDefaults)
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
