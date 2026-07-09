import CoreData
import DispatchKit
import os
import SwiftData
import SwiftUI
import UserNotifications

private let seedLog = Logger(subsystem: "io.robbie.Dispatch", category: "seed")
private let migrationLog = Logger(subsystem: "io.robbie.Dispatch", category: "migration")

@main
struct DispatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer
    let themeStore: ThemeStore
    let awakeStore: AwakeStore
    let notificationPrefs: NotificationPrefs
    let visualizationFilterStore: VisualizationFilterStore
    let surveyPresenter = SurveyPresenter()
    let notificationScheduler: NotificationScheduler
    let appLockStore: AppLockStore
    let privacyCoverWindow: PrivacyCoverWindow
    let permissionCascade: PermissionCascade
    let workoutEndObserver: WorkoutEndObserver
    let remoteChangeObserver: RemoteChangeObserver
    private let appDefaults: UserDefaults
    private let isTestEnvironment: Bool
    @State private var backgroundedAt: Date?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isTestEnvironment = arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        if isTestEnvironment,
           let uiTestingDefaults = UserDefaults(suiteName: "ui-testing") {
            uiTestingDefaults.removePersistentDomain(forName: "ui-testing")
            appDefaults = uiTestingDefaults
        } else {
            appDefaults = .standard
        }

        // Container construction consults the sync policy (defaults suite +
        // test environment), so defaults selection above must precede it.
        let syncPolicy = SyncPolicy(defaults: appDefaults, isTestEnvironment: isTestEnvironment)
        let (madeContainer, cloudKitActive) = Self.makeContainer(
            syncEnabled: syncPolicy.shouldSync, inMemory: isTestEnvironment
        )
        container = madeContainer

        // One-time legacy default-question ID migration. Must run before
        // anything reads questions — in particular before
        // VisualizationFilterStore below, which caches the hidden-ID set from
        // defaults at init.
        do {
            try DefaultQuestionIDMigration.runIfNeeded(
                context: ModelContext(container), defaults: appDefaults
            )
        } catch {
            migrationLog.error("default-question ID migration failed: \(error, privacy: .public)")
        }

        themeStore = ThemeStore(defaults: appDefaults)
        awakeStore = AwakeStore(defaults: appDefaults)
        notificationPrefs = NotificationPrefs(defaults: appDefaults)
        visualizationFilterStore = VisualizationFilterStore(defaults: appDefaults)
        appLockStore = AppLockStore(defaults: appDefaults, isTestEnvironment: isTestEnvironment)
        appLockStore.lockAtLaunchIfNeeded()
        if arguments.contains("--enable-app-lock") {
            appLockStore.forceLockForUITesting()
        }
        privacyCoverWindow = PrivacyCoverWindow(appLockStore: appLockStore, themeStore: themeStore)

        let scheduler = NotificationScheduler(
            container: container, prefs: notificationPrefs, isTestEnvironment: isTestEnvironment
        )
        notificationScheduler = scheduler
        UNUserNotificationCenter.current().delegate = scheduler

        permissionCascade = PermissionCascade(
            healthReader: HealthKitReader(),
            notificationScheduler: scheduler,
            notificationPrefs: notificationPrefs,
            awakeStore: awakeStore,
            defaults: appDefaults,
            isTestEnvironment: isTestEnvironment
        )

        let workoutObserver = WorkoutEndObserver(
            container: container, awakeStore: awakeStore, defaults: appDefaults,
            isTestEnvironment: isTestEnvironment
        )
        workoutEndObserver = workoutObserver

        // Remote-change reactions: dedupe/vocabulary/Spotlight run on a
        // background context inside the observer; the callback re-plans
        // notifications (which also re-registers the quick-answer category)
        // and refreshes the workout-end observer — a workout-end group
        // created or deleted on another device must arm/disarm the
        // HKObserverQuery without a relaunch (refresh() is idempotent).
        // Locals (not self) captured — self isn't fully initialized yet.
        let prefsForReplan = notificationPrefs
        let awakeForReplan = awakeStore
        remoteChangeObserver = RemoteChangeObserver(
            container: container,
            isTestEnvironment: isTestEnvironment,
            isSyncActive: cloudKitActive
        ) {
            scheduler.replan(prefs: prefsForReplan, awakeStore: awakeForReplan)
            workoutObserver.refresh()
        }

        seedDefaultQuestionsIfNeeded()
        if arguments.contains("--skip-onboarding") {
            appDefaults.set(true, forKey: OnboardingFlag.key)
        }

        scheduler.registerCategory()

        AppActions.shared.register(
            surveyPresenter: surveyPresenter,
            awakeStore: awakeStore,
            notificationScheduler: scheduler,
            notificationPrefs: notificationPrefs
        )

        // Register the workout-end observer at LAUNCH, not just onAppear:
        // HealthKit background delivery relaunches a terminated app headless
        // (no scene, ContentView.onAppear never runs), so the HKObserverQuery
        // must be re-registered here or the fire is missed and HealthKit
        // throttles future deliveries. Self-gating for the test environment
        // and the no-groups case; the onAppear call stays for group edits.
        workoutEndObserver.refresh()

        // Subscribe to remote-change notifications and schedule the launch
        // SyncDedupe pass (debounced with the observer's first fire).
        // Test-gated internally.
        remoteChangeObserver.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(themeStore)
                .environment(awakeStore)
                .environment(visualizationFilterStore)
                .environment(surveyPresenter)
                .environment(notificationScheduler)
                .environment(appLockStore)
                .environment(permissionCascade)
                .environment(workoutEndObserver)
                .environment(remoteChangeObserver)
                .environment(\.appDefaults, appDefaults)
                .environment(\.notificationPrefs, notificationPrefs)
                .onOpenURL { url in
                    // dispatch://report[?trigger=control] — widget "New
                    // Report" links (trigger=widget) and the Control Center
                    // control (trigger=control, via OpenURLIntent).
                    guard url.scheme == "dispatch", url.host() == "report" else { return }
                    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems ?? []
                    let isControl = queryItems.contains { $0.name == "trigger" && $0.value == "control" }
                    let trigger: ReportTrigger = isControl ? .control : .widget
                    surveyPresenter.request = SurveyRequest(kind: .regular, trigger: trigger)
                }
                .onAppear {
                    if appDefaults.bool(forKey: OnboardingFlag.key) {
                        notificationScheduler.requestPermissionIfNeeded(prefs: notificationPrefs, awakeStore: awakeStore)
                    }
                    // Start (or stop) the workout-end observer according to
                    // the current groups; test-gated internally.
                    workoutEndObserver.refresh()
                    // Cold launch with lock enabled (or the --enable-app-lock
                    // forced-lock UI-test path): the window scene is connected
                    // by now, so raise the lock window before content is seen.
                    if appLockStore.isLocked {
                        privacyCoverWindow.show()
                    }
                }
                .task {
                    // Upgrade-install permission top-up: existing installs
                    // completed onboarding before the Motion/medications
                    // cascade steps existed, so run JUST those two (once,
                    // defaults-flag-gated inside). Post-onboarding installs
                    // only — fresh installs get both via the onboarding
                    // cascade, which sets the same flag. Test-gated inside.
                    if appDefaults.bool(forKey: OnboardingFlag.key) {
                        await permissionCascade.runUpgradeTopUpIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    switch newPhase {
                    case .active:
                        notificationScheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                        // Foreground poke: sync may have changed the shared
                        // store while the widget had no reason to refresh.
                        if !isTestEnvironment {
                            WidgetRefresher.reload()
                        }
                        appLockStore.evaluateReturnFromBackground(backgroundedAt: backgroundedAt)
                        backgroundedAt = nil
                        // Decide first, then adjust the cover in the same
                        // main-actor turn: keep the window while locked (it
                        // hosts AppLockView's unlock flow), drop it otherwise.
                        if appLockStore.isLocked || appLockStore.isCovered {
                            privacyCoverWindow.show()
                        } else {
                            privacyCoverWindow.hide()
                        }
                    case .inactive, .background:
                        // Synchronous, same handler — the cover must be up
                        // before the app-switcher snapshot is taken and before
                        // any frame of real content can flash on return.
                        // coverForBackgroundingIfNeeded is a no-op while
                        // already locked/covered, so the .inactive fired by
                        // the Face ID prompt itself can't re-lock or disturb
                        // an in-progress unlock.
                        appLockStore.coverForBackgroundingIfNeeded()
                        if appLockStore.isCovered || appLockStore.isLocked {
                            privacyCoverWindow.show()
                        }
                        if newPhase == .background {
                            backgroundedAt = Date()
                        }
                    default:
                        break
                    }
                }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--dump-pending") else { return }
                    // Diagnostic harness for verifying the replan
                    // remove-before-add sequencing empirically: replans on
                    // launch, waits for the async add() calls to land, then
                    // prints the pending `prompt-` request count so it can
                    // be grepped from `xcrun simctl launch --console-pty`
                    // output. Kept permanently behind this launch argument
                    // as a lightweight diagnostic; no effect on normal runs.
                    await notificationScheduler.replanNow(prefs: notificationPrefs, awakeStore: awakeStore)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                    let count = pending.filter { $0.identifier.hasPrefix(NotificationIdentifiers.promptPrefix) }.count
                    print("PENDING-PROMPTS: \(count)")
                }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--probe-remote-change") else { return }
                    // Diagnostic harness proving NSPersistentStoreRemoteChange
                    // is reachable through SwiftData's stack (plan 13): counts
                    // notifications observed around a background-context save
                    // and prints the tally for `simctl launch --console-pty`
                    // grepping. Kept permanently behind this launch argument,
                    // same pattern as --dump-pending above.
                    let counter = OSAllocatedUnfairLock(initialState: 0)
                    let observer = NotificationCenter.default.addObserver(
                        forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
                    ) { _ in
                        counter.withLock { $0 += 1 }
                    }
                    let context = ModelContext(container)
                    let question = Question()
                    question.prompt = "remote-change probe"
                    question.isEnabled = false
                    context.insert(question)
                    try? context.save()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let observed = counter.withLock { $0 }
                    print("REMOTE-CHANGE-EVENTS: \(observed)")
                    syncLog.info("REMOTE-CHANGE-EVENTS: \(observed, privacy: .public)")
                    NotificationCenter.default.removeObserver(observer)
                    // Remove the probe row — it must not linger in the store
                    // (or sync) after the diagnostic run.
                    context.delete(question)
                    try? context.save()
                }
        }
        .modelContainer(container)
    }

    /// Builds the app's ModelContainer against the SAME default store URL in
    /// both modes — CloudKit mirroring attaches to the existing store, so
    /// toggling sync never migrates or relocates data.
    ///
    /// The app must NEVER fail to launch over sync: the CloudKit-backed
    /// configuration is wrapped in do/catch and any construction error is
    /// logged and answered with the plain local container. The local path
    /// passes `cloudKitDatabase: .none` explicitly — with the iCloud
    /// entitlements now present, the default `.automatic` would infer
    /// CloudKit from them, which must not happen for the sync-disabled and
    /// test paths.
    ///
    /// Test launches (`--ui-testing`/`--mock-sensors`) get an in-memory store:
    /// the on-disk store persists across UI-test runs on the same simulator,
    /// so data created by one run (reports, prompt groups) pollutes the next.
    /// No UI test relies on persistence across separate launches, and test
    /// defaults are already wiped per launch, so per-launch stores match the
    /// existing test isolation model.
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
        // Plan 14: the store lives in the App Group container so the widget
        // extension can query it directly. Resolution runs the one-time
        // legacy → App Group migration BEFORE any container is built.
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
            // Same hard-failure semantics the app has always had for an
            // unopenable local store (previously `try!` at this call site) —
            // this is not a sync failure.
            fatalError("failed to open local model container: \(error)")
        }
    }

    /// Where the on-disk store lives, running the one-time legacy →
    /// App Group migration first (plan 14: widgets read the store directly,
    /// so it must live in the shared container). Never-fail-launch holds:
    /// a missing App Group entitlement or a failed move logs loudly and
    /// falls back to the legacy sandbox URL — widgets then show their
    /// placeholder, but the app runs with its data intact.
    private static func resolveStoreURL() -> URL {
        let legacy = StoreLocation.legacyURL()
        guard let groupURL = StoreLocation.appGroupURL() else {
            migrationLog.error("APP GROUP CONTAINER UNAVAILABLE — running from legacy store URL")
            return legacy
        }
        switch StoreLocation.migrate(from: legacy, to: groupURL) {
        case .migrated:
            migrationLog.info("store migrated into App Group container")
        case .alreadyInPlace:
            break
        case .freshInstall:
            migrationLog.info("fresh install — creating store in App Group container")
        case .failed(let reason):
            migrationLog.error("STORE MIGRATION FAILED — running from legacy store URL: \(reason, privacy: .public)")
            return legacy
        case .failedForward(let reason):
            // Rollback failed too, so the store (and, force-moved, its WAL)
            // ended up at the destination — run from there; the legacy URL
            // no longer holds a coherent store.
            migrationLog.error("STORE MIGRATION FAILED FORWARD — running from App Group store URL: \(reason, privacy: .public)")
        }
        return groupURL
    }

    private func seedDefaultQuestionsIfNeeded() {
        let context = ModelContext(container)
        guard ((try? context.fetchCount(FetchDescriptor<Question>())) ?? 0) == 0 else { return }
        // Table-driven from the frozen catalog: deterministic UUIDv5
        // identifiers so fresh installs on different devices seed IDENTICAL
        // IDs and iCloud sync merges rather than duplicates.
        for (index, seed) in DefaultQuestions.all.enumerated() {
            let question = Question()
            question.uniqueIdentifier = seed.identifier
            question.prompt = seed.prompt
            question.type = seed.type
            question.sortOrder = index
            question.reportKinds = seed.reportKinds
            question.choices = seed.choices
            context.insert(question)
        }
        do {
            try context.save()
        } catch {
            seedLog.error("failed to seed default questions: \(error, privacy: .public)")
        }
    }
}
