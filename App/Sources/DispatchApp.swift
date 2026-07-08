import DispatchKit
import os
import SwiftData
import SwiftUI
import UserNotifications

private let seedLog = Logger(subsystem: "io.robbie.Dispatch", category: "seed")
private let migrationLog = Logger(subsystem: "io.robbie.Dispatch", category: "migrationLog")

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
        container = Self.makeContainer(syncEnabled: syncPolicy.shouldSync)

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
            isTestEnvironment: isTestEnvironment
        )

        workoutEndObserver = WorkoutEndObserver(
            container: container, awakeStore: awakeStore, defaults: appDefaults,
            isTestEnvironment: isTestEnvironment
        )

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
                .environment(\.appDefaults, appDefaults)
                .environment(\.notificationPrefs, notificationPrefs)
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
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    switch newPhase {
                    case .active:
                        notificationScheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
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
    private static func makeContainer(syncEnabled: Bool) -> ModelContainer {
        let schema = Schema(DispatchStore.allModels)
        if syncEnabled {
            do {
                let config = ModelConfiguration(
                    schema: schema,
                    cloudKitDatabase: .private(SyncPolicy.containerIdentifier)
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                syncLog.info("CloudKit-mirrored container active (\(SyncPolicy.containerIdentifier, privacy: .public))")
                return container
            } catch {
                syncLog.error("CloudKit container construction failed, falling back to local: \(error, privacy: .public)")
            }
        }
        do {
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            syncLog.info("local (non-CloudKit) container active")
            return container
        } catch {
            // Same hard-failure semantics the app has always had for an
            // unopenable local store (previously `try!` at this call site) —
            // this is not a sync failure.
            fatalError("failed to open local model container: \(error)")
        }
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
