import CoreData
import DispatchKit
import os
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

private let seedLog = Logger(subsystem: "io.robbie.Dispatch", category: "seed")
private let urlLog = Logger(subsystem: "io.robbie.Dispatch", category: "url")
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
    // PLAN-39 TASK 0 PROBE — remove after measurement.
    let sleepDeliveryProbe: SleepDeliveryProbe
    let visitObserver: VisitObserver
    let calendarEventObserver: CalendarEventObserver
    let backupManager: BackupManager
    let webhookManager: WebhookManager
    let remoteChangeObserver: RemoteChangeObserver
    let syncDiagnostics: SyncDiagnostics
    let spotifyController = SpotifyController()
    private let appDefaults: UserDefaults
    private let isTestEnvironment: Bool
    @State private var backgroundedAt: Date?

    init() {
        // Device provenance (plan 19): inject the device name for report
        // stamping. Read UNCONDITIONALLY — until the requested
        // user-assigned-device-name entitlement is granted this returns the
        // generic "iPhone" (accepted and expected); the grant upgrades the
        // value in place with no code change. See DeviceIdentity.
        DeviceIdentity.deviceName = UIDevice.current.name

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
        let (madeContainer, cloudKitActive, storeURL) = Self.makeContainer(
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
        // Screenshot rig: `--theme <name>` pins the launch theme so each App
        // Store shot can use a different palette color (the original Reporter
        // listing look). Test-environment-gated like every launch argument —
        // production launches ignore it entirely.
        if isTestEnvironment,
           let flagIndex = arguments.firstIndex(of: "--theme"),
           arguments.indices.contains(flagIndex + 1),
           let forced = Theme(rawValue: arguments[flagIndex + 1]) {
            themeStore.theme = forced
        }
        awakeStore = AwakeStore(defaults: appDefaults)
        notificationPrefs = NotificationPrefs(defaults: appDefaults)
        // Plan 40: migrate the single digestEnabled toggle to the schedules
        // list once, before the first replan reads digestSchedules.
        notificationPrefs.migrateDigestSchedulesIfNeeded()
        visualizationFilterStore = VisualizationFilterStore(defaults: appDefaults)
        appLockStore = AppLockStore(defaults: appDefaults, isTestEnvironment: isTestEnvironment)
        appLockStore.lockAtLaunchIfNeeded()
        if arguments.contains("--enable-app-lock") {
            appLockStore.forceLockForUITesting()
        }
        privacyCoverWindow = PrivacyCoverWindow(appLockStore: appLockStore, themeStore: themeStore)

        // Focus filter state (plan 15) lives in the App Group defaults in
        // production — DispatchFocusFilter.perform() writes it there so a
        // background-launched intent run and the foreground app read the
        // same state. Tests use the isolated per-launch suite instead
        // (real Focus state can't leak in), with an optional injection
        // hook: FOCUS_FILTER_STATE={json} in the launch environment.
        let focusFilterDefaults: UserDefaults
        if isTestEnvironment {
            focusFilterDefaults = appDefaults
            if let json = ProcessInfo.processInfo.environment["FOCUS_FILTER_STATE"] {
                appDefaults.set(Data(json.utf8), forKey: FocusFilterState.defaultsKey)
            }
        } else {
            focusFilterDefaults = UserDefaults(suiteName: StoreLocation.appGroupID) ?? .standard
        }

        let scheduler = NotificationScheduler(
            container: container, prefs: notificationPrefs, isTestEnvironment: isTestEnvironment,
            focusFilterDefaults: focusFilterDefaults
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

        // PLAN-39 TASK 0 PROBE — remove after measurement. Diagnostic
        // sleepAnalysis delivery-timing observer, toggled in Settings >
        // Sensors; persisted flag so headless background relaunches
        // re-register it below.
        sleepDeliveryProbe = SleepDeliveryProbe(
            defaults: appDefaults, isTestEnvironment: isTestEnvironment
        )

        // Visit-arrival observer (plan 16): same lifecycle contract as the
        // workout-end observer — launch registration, refresh on group
        // edits and remote-change sync, test-gated internally.
        let madeVisitObserver = VisitObserver(
            container: container, awakeStore: awakeStore, defaults: appDefaults,
            focusFilterDefaults: focusFilterDefaults, isTestEnvironment: isTestEnvironment
        )
        visitObserver = madeVisitObserver

        // Automatic rotating backups (plan 16): foreground-scheduled (scene
        // active + report save), off-main export, no background tasks.
        // storeCreatedAt (the store file's on-disk creation date — the
        // cheapest honest "fresh install" signal; the fresh-install path
        // creates the file during this same launch) + cloudKitActive feed
        // the first-launch guard: never auto-backup a fresh store before
        // initial sync has been observed. nil for in-memory test stores.
        let storeCreatedAt = storeURL.flatMap {
            (try? FileManager.default.attributesOfItem(
                atPath: $0.path(percentEncoded: false)))?[.creationDate] as? Date
        }
        // Screenshot fixture (review pass): the data-settings shot over an
        // empty backup state reads as broken UI. Seed a plausible rotation
        // and inject its throwaway directory — BackupManager then lists it
        // for the caption count. Test-environment + --demo-data gated.
        var demoBackupDirectory: URL?
        if isTestEnvironment, arguments.contains("--demo-data") {
            demoBackupDirectory = try? DemoData.seedBackupFixture(defaults: appDefaults)
        }
        backupManager = BackupManager(
            container: container, defaults: appDefaults, isTestEnvironment: isTestEnvironment,
            directory: demoBackupDirectory,
            storeCreatedAt: storeCreatedAt, isSyncActive: cloudKitActive
        )

        // Report webhooks (plan 24): queue-and-drain. The queue and the
        // device-local config live in the App Group defaults (the widget
        // process enqueues into the same suite); tests use the isolated
        // per-launch suite plus a stub transport (`--stub-webhook`) so no
        // test ever touches the real network.
        let webhookDefaults = isTestEnvironment
            ? appDefaults
            : (UserDefaults(suiteName: StoreLocation.appGroupID) ?? .standard)
        let webhookTransport: any WebhookTransport = arguments.contains("--stub-webhook")
            ? StubWebhookTransport()
            : URLSession.shared
        let madeWebhookManager = WebhookManager(
            container: container, defaults: webhookDefaults,
            transport: webhookTransport, isTestEnvironment: isTestEnvironment
        )
        webhookManager = madeWebhookManager
        // The notification quick-answer save runs in this process — deliver
        // immediately, like any in-app save.
        scheduler.reportFiledWebhookHook = { reportID in
            madeWebhookManager.enqueueAndDrain(reportID: reportID)
        }

        // Remote-change reactions: dedupe/vocabulary/Spotlight run on a
        // background context inside the observer; the callback re-plans
        // notifications (which also re-registers the quick-answer category)
        // and refreshes the event observers — a workout-end, visit-arrival,
        // or calendar group created or deleted on another device must
        // arm/disarm its monitoring without a relaunch (refresh() is
        // idempotent).
        // Locals (not self) captured — self isn't fully initialized yet.
        let prefsForReplan = notificationPrefs
        let awakeForReplan = awakeStore

        // Calendar event-end observer (plan 31): the schedule-ahead sibling
        // of the visit observer — it never posts prompts itself (EventKit
        // has no background wake); it feeds replanNow's calendar plans via
        // the scheduler seam and keeps them fresh on .EKEventStoreChanged
        // (2s-debounced replan). Test-gated internally.
        let madeCalendarObserver = CalendarEventObserver(
            container: container, isTestEnvironment: isTestEnvironment,
            replan: { scheduler.replan(prefs: prefsForReplan, awakeStore: awakeForReplan) }
        )
        calendarEventObserver = madeCalendarObserver
        scheduler.calendarEventSource = madeCalendarObserver
        // Plan 37: the diagnostics sink. Constructed always (the screen is
        // reachable with sync off), but only subscribes to CloudKit events
        // when sync is active and never under test (see the .task wiring in
        // the scene). Under test it rides the isolated per-launch appDefaults
        // suite selected above.
        let diagnostics = SyncDiagnostics(
            defaults: appDefaults, isTestEnvironment: isTestEnvironment, isSyncActive: cloudKitActive
        )
        syncDiagnostics = diagnostics
        remoteChangeObserver = RemoteChangeObserver(
            container: container,
            defaults: appDefaults,
            isTestEnvironment: isTestEnvironment,
            isSyncActive: cloudKitActive,
            onRemoteChangesApplied: { recentReportDates in
                // Synced-report nag reconciliation (plan 19) BEFORE the replan,
                // so the replan reads the updated lastActedAt — a report filed
                // on the watch (or another phone) quiets past-due nag chains
                // exactly as an in-app save would.
                scheduler.syncedReportsArrived(reportDates: recentReportDates)
                scheduler.replan(prefs: prefsForReplan, awakeStore: awakeForReplan)
                workoutObserver.refresh()
                madeVisitObserver.refresh()
                madeCalendarObserver.refresh()
            },
            onDiagnosticsEvent: { event in diagnostics.record(event) },
            onDedupePass: { summary, date in diagnostics.recordDedupePass(summary, at: date) }
        )

        seedDefaultQuestionsIfNeeded()
        // Screenshot fixture (plan 23): test-environment-gated like every
        // launch argument — the in-memory store guarantee above means this
        // can never touch (or sync) real data.
        if isTestEnvironment, arguments.contains("--demo-data") {
            do {
                try DemoData.seed(into: ModelContext(container))
            } catch {
                seedLog.error("demo-data seeding failed: \(error, privacy: .public)")
            }
        }
        // Pager-dots density fixture (PR #41 review): pads to 15 enabled
        // questions so UI tests can pin the many-page dot layout.
        if isTestEnvironment, arguments.contains("--demo-many-questions") {
            do {
                try DemoData.seedExtraQuestions(into: ModelContext(container))
            } catch {
                seedLog.error("demo-many-questions seeding failed: \(error, privacy: .public)")
            }
        }
        if arguments.contains("--skip-onboarding") {
            appDefaults.set(true, forKey: OnboardingFlag.key)
        }

        scheduler.registerCategory()

        // One-time full replan after the stamp formatter's en_US_POSIX pin
        // (plan 17 hygiene) — see runStampMigrationReplanIfNeeded. Fires
        // exactly once per install (ScheduleStampVersion marker), logged.
        scheduler.runStampMigrationReplanIfNeeded(
            defaults: appDefaults, prefs: notificationPrefs, awakeStore: awakeStore
        )

        AppActions.shared.register(
            surveyPresenter: surveyPresenter,
            awakeStore: awakeStore,
            notificationScheduler: scheduler,
            notificationPrefs: notificationPrefs
        )

        // Control Center control: its OpenIntent's perform() runs in THIS
        // process (dual target membership) and routes through the same
        // AppActions → SurveyPresenter path as StartReportIntent, so the
        // survey presentation stays behind ContentView's lock-gated cover.
        StartReportControlIntent.startReportInApp = {
            AppActions.shared.surveyPresenter?.request = SurveyRequest(kind: .regular, trigger: .control)
        }

        // Focus filter (plan 15): perform() runs in this process (the
        // system launches the app in the background when it isn't running),
        // so the intent can trigger an immediate replan after writing/
        // clearing the FocusFilterState. Same hook pattern as the control
        // intent above.
        DispatchFocusFilter.replanInApp = {
            scheduler.replan(prefs: prefsForReplan, awakeStore: awakeForReplan)
        }
        // Deactivation (state-clear) path: floor past-parent nag arithmetic
        // before the replan so prompts suppressed by the filter can't
        // resurrect nag chains (see NotificationScheduler.focusFilterCleared).
        DispatchFocusFilter.filterClearedInApp = {
            scheduler.focusFilterCleared()
        }

        // Register the workout-end observer at LAUNCH, not just onAppear:
        // HealthKit background delivery relaunches a terminated app headless
        // (no scene, ContentView.onAppear never runs), so the HKObserverQuery
        // must be re-registered here or the fire is missed and HealthKit
        // throttles future deliveries. Self-gating for the test environment
        // and the no-groups case; the onAppear call stays for group edits.
        workoutEndObserver.refresh()

        // PLAN-39 TASK 0 PROBE — remove after measurement. Same launch
        // registration rationale as the workout observer directly above.
        sleepDeliveryProbe.refresh()

        // Visit monitoring must likewise restart at LAUNCH: per Apple's
        // startMonitoringVisits() docs the system relaunches a terminated
        // app to deliver visit events, and "upon relaunch, recreate your
        // location manager object and assign a delegate" — this refresh is
        // that re-registration (self-gating for tests / no visit groups /
        // missing Always authorization).
        visitObserver.refresh()

        // Calendar observer launch refresh (plan 31): subscribes to
        // .EKEventStoreChanged when an enabled calendar group + full access
        // exist. Foreground-only freshness by design — EventKit never
        // relaunches the app, so unlike the two observers above there is no
        // relaunch contract to honor; the launch replan covers scheduling.
        calendarEventObserver.refresh()

        // Subscribe to remote-change notifications and schedule the launch
        // SyncDedupe pass (debounced with the observer's first fire).
        // Test-gated internally.
        remoteChangeObserver.start()

        // Plan 37: CloudKit event observation for the diagnostics timeline —
        // same gate as the remote-change subscription (a local-only store has
        // no CloudKit events by definition). Internally guards against the
        // test environment and double-subscription.
        if cloudKitActive {
            syncDiagnostics.startCloudKitObservation()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Screenshot rig: invisible marker exposing the ACTIVE theme
                // to the AX tree so the suite can verify --theme applied
                // before capturing (a wrong-theme shot slipped a review).
                // Test-environment-only; 1pt and 2% opacity — invisible in
                // captures but present as a StaticText.
                .overlay(alignment: .topLeading) {
                    if isTestEnvironment {
                        Text(themeStore.theme.rawValue)
                            .font(.system(size: 4))
                            .opacity(0.02)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("active-theme")
                    }
                }
                .environment(themeStore)
                .environment(awakeStore)
                .environment(visualizationFilterStore)
                .environment(surveyPresenter)
                .environment(notificationScheduler)
                .environment(appLockStore)
                .environment(permissionCascade)
                .environment(workoutEndObserver)
                .environment(sleepDeliveryProbe)
                .environment(visitObserver)
                .environment(calendarEventObserver)
                .environment(backupManager)
                .environment(webhookManager)
                .environment(remoteChangeObserver)
                .environment(syncDiagnostics)
                .environment(spotifyController)
                .environment(\.appDefaults, appDefaults)
                .environment(\.notificationPrefs, notificationPrefs)
                .onOpenURL { url in
                    // Lock gate first: a URL arriving while the app is locked
                    // or covered (e.g. the dispatch-spotify://callback OAuth
                    // return after >grace in the Spotify app) is queued, never
                    // processed invisibly behind the cover — and, when locked,
                    // re-requests the Face ID prompt so the return can't
                    // strand the user on the lock screen. Queued URLs route
                    // after a successful unlock (or on returning to the
                    // foreground without locking); a cancelled/failed unlock
                    // keeps them queued for the next attempt.
                    if appLockStore.deferURLIfNeeded(url) {
                        urlLog.info("onOpenURL deferred behind lock/cover: \(url.scheme ?? "?", privacy: .public)")
                        return
                    }
                    urlLog.info("onOpenURL routing immediately: \(url.scheme ?? "?", privacy: .public)")
                    route(url: url)
                }
                .onChange(of: appLockStore.isLocked) { _, isLocked in
                    guard !isLocked else { return }
                    drainDeferredURLs()
                }
                .onAppear {
                    if appDefaults.bool(forKey: OnboardingFlag.key) {
                        notificationScheduler.requestPermissionIfNeeded(prefs: notificationPrefs, awakeStore: awakeStore)
                    }
                    // Start (or stop) the event observers according to the
                    // current groups; test-gated internally.
                    workoutEndObserver.refresh()
                    visitObserver.refresh()
                    calendarEventObserver.refresh()
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
                        // Drain the widget quick-answer marker BEFORE the
                        // replan: the intent files from the widget-extension
                        // process and leaves lastActedAt/nag cancellation to
                        // this app-side drain (see WidgetQuickAnswerMarker),
                        // and the replan must read the updated lastActedAt.
                        // Test environments skip it — the shared App Group
                        // suite must not leak real markers into UI tests.
                        if !isTestEnvironment {
                            notificationScheduler.drainWidgetQuickAnswerActions(
                                from: UserDefaults(suiteName: StoreLocation.appGroupID))
                        }
                        notificationScheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                        // Backup staleness check (plan 16): cheap when fresh,
                        // writes a rotating v2 export off-main when >20h old.
                        backupManager.backUpIfStale()
                        // Webhook drain (plan 24): deliver anything queued —
                        // widget quick-answers enqueued by the extension
                        // process (after their marker drain above), plus any
                        // reports still owed retries. No-op when disabled.
                        webhookManager.drain()
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
                            // Covered-but-never-locked return (within grace):
                            // isLocked never flips, so the onChange drain
                            // doesn't fire — route anything queued while the
                            // cover was up now that content is visible again.
                            drainDeferredURLs()
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
                    guard ProcessInfo.processInfo.arguments.contains("--probe-focus-filter") else { return }
                    // Diagnostic harness for the Focus filter lifecycle
                    // (plan 15), grep-able from `simctl launch --console-pty`
                    // output; kept permanently behind this launch argument,
                    // same pattern as --dump-pending below. The iOS 26.5
                    // SIMULATOR has no Focus pane in Settings (no way to
                    // attach a filter to a Focus), so this probe exercises
                    // what IS observable there: (1) `DispatchFocusFilter
                    // .current` with no filter active — OBSERVED to return
                    // an all-defaults instance (displayName nil) rather
                    // than throw the documented notFound, which is why
                    // perform() never consults it; (2) perform() with
                    // configured parameters (an activation delivery)
                    // writes FocusFilterState and replans; (3) perform()
                    // on an all-defaults instance (a deactivation delivery
                    // per Apple's documented lifecycle) clears it.
                    // Residue guard: the probe writes real FocusFilterState
                    // into the App Group defaults; clear it no matter how
                    // the probe exits (early return, throw, partial run) so
                    // a diagnostic run can never leave a phantom filter
                    // muting the real schedule.
                    let groupDefaults = UserDefaults(suiteName: StoreLocation.appGroupID)
                    defer {
                        if let groupDefaults { FocusFilterState.clear(in: groupDefaults) }
                    }
                    do {
                        let current = try await DispatchFocusFilter.current
                        // groups= verifies the framework preserves nil for an
                        // unset optional [Entity] parameter (nil-vs-empty is
                        // load-bearing: nil ⇒ all groups, [] ⇒ mute all).
                        print("FOCUS-PROBE-CURRENT: \(current.displayName ?? "<nil>") groups=\(current.allowedGroups.map { "\($0.count)" } ?? "<nil>")")
                    } catch {
                        print("FOCUS-PROBE-CURRENT-THREW: \(error)")
                    }
                    // let, not var: @Parameter assignment routes through the
                    // wrapper's nonmutating setter, so the value itself is
                    // never mutated (var draws a compiler warning).
                    let activation = DispatchFocusFilter()
                    activation.displayName = "Work"
                    activation.pauseGlobalPrompts = true
                    _ = try? await activation.perform()
                    let active = groupDefaults.flatMap(FocusFilterState.read(from:))
                    print("FOCUS-PROBE-ACTIVATED: label=\(active?.label ?? "<nil>") pauseGlobal=\(active?.pauseGlobal == true) allowedGroupIDs=\(active?.allowedGroupIDs.map { "\($0.count)" } ?? "<nil>") schedulerSees=\(notificationScheduler.activeFocusFilter?.label ?? "<nil>")")
                    _ = try? await DispatchFocusFilter().perform()
                    let cleared = groupDefaults.flatMap(FocusFilterState.read(from:))
                    print("FOCUS-PROBE-DEACTIVATED: state=\(cleared == nil ? "cleared" : "STILL PRESENT")")
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
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--probe-cloudkit-events") else { return }
                    // Plan 37 diagnostic: is NSPersistentCloudKitContainer's
                    // eventChangedNotification reachable through SwiftData's
                    // CloudKit mirroring stack when subscribed with object:nil
                    // (SwiftData never exposes the container)? Same empirical
                    // question plan 13 answered for NSPersistentStoreRemoteChange
                    // via --probe-remote-change. Subscribe, save a report while
                    // running, and grep `simctl launch --console-pty` output
                    // for CLOUDKIT-EVENT-PROBE lines. RUN ON A SIGNED-IN
                    // iCloud DEVICE with sync active — a simulator without an
                    // iCloud account produces no events and is inconclusive.
                    let observer = NotificationCenter.default.addObserver(
                        forName: NSPersistentCloudKitContainer.eventChangedNotification,
                        object: nil, queue: .main
                    ) { note in
                        guard let event = note.userInfo?[
                            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                        ] as? NSPersistentCloudKitContainer.Event else { return }
                        let typeName: String
                        switch event.type {
                        case .setup: typeName = "setup"
                        case .import: typeName = "import"
                        case .export: typeName = "export"
                        @unknown default: typeName = "unknown"
                        }
                        let ended = event.endDate != nil
                        print("CLOUDKIT-EVENT-PROBE: type=\(typeName) ended=\(ended) succeeded=\(event.succeeded) error=\(event.error.map { "\($0)" } ?? "nil")")
                        syncLog.info("CLOUDKIT-EVENT-PROBE: type=\(typeName, privacy: .public) ended=\(ended, privacy: .public) succeeded=\(event.succeeded, privacy: .public)")
                    }
                    // Leave the observer live for the session; the probe is a
                    // manual diagnostic run, not a steady-state subscription.
                    _ = observer
                    print("CLOUDKIT-EVENT-PROBE: subscribed (object:nil) — file a report to elicit export events")
                }
        }
        .modelContainer(container)
    }

    /// Routes an opened URL once it is allowed to be processed (app neither
    /// locked nor covered — see the onOpenURL lock gate).
    ///
    /// dispatch://report — home/lock screen WIDGET TAPS only (widgetURL/
    /// Link). Per Apple's widget docs ("Respond to user interactions"),
    /// tap-to-open-app from a widget is URL-based by design, so the scheme
    /// stays for those. The Control Center control no longer routes through
    /// here — it uses StartReportControlIntent (an OpenIntent in both
    /// targets) whose perform() runs in-app.
    /// dispatch-spotify://callback — Spotify auth redirect (plan 26). Routed
    /// FIRST, on its own scheme, so the widget-tap guard below stays
    /// untouched.
    private func route(url: URL) {
        if url.scheme == "dispatch-spotify" {
            spotifyController.handleCallback(url: url)
            return
        }
        guard url.scheme == "dispatch", url.host() == "report" else { return }
        surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .widget)
    }

    /// Routes every URL queued behind the lock/cover, in arrival order.
    private func drainDeferredURLs() {
        let urls = appLockStore.drainPendingURLs()
        if !urls.isEmpty {
            urlLog.info("draining \(urls.count, privacy: .public) deferred URL(s) after unlock/uncover")
        }
        for url in urls {
            route(url: url)
        }
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
    ) -> (ModelContainer, cloudKitActive: Bool, storeURL: URL?) {
        let schema = Schema(DispatchStore.allModels)
        if inMemory {
            do {
                let config = ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: schema, configurations: [config])
                syncLog.info("in-memory container active (test environment)")
                return (container, cloudKitActive: false, storeURL: nil)
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
                return (container, cloudKitActive: true, storeURL: storeURL)
            } catch {
                syncLog.error("CloudKit container construction failed, falling back to local: \(error, privacy: .public)")
            }
        }
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            syncLog.info("local (non-CloudKit) container active")
            return (container, cloudKitActive: false, storeURL: storeURL)
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
        // Table-driven from the frozen catalog: deterministic UUIDv5
        // identifiers so fresh installs on different devices seed IDENTICAL
        // IDs and iCloud sync merges rather than duplicates. Shared with the
        // Delete All Data reseed (kit-side seedIfEmpty).
        do {
            try DefaultQuestions.seedIfEmpty(into: ModelContext(container))
        } catch {
            seedLog.error("failed to seed default questions: \(error, privacy: .public)")
        }
    }
}
