import DispatchKit
import os
import SwiftData
import SwiftUI
import UserNotifications

private let seedLog = Logger(subsystem: "io.robbie.Dispatch", category: "seed")

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
    private let appDefaults: UserDefaults
    private let isTestEnvironment: Bool
    @State private var backgroundedAt: Date?

    init() {
        container = try! ModelContainer(for: Schema(DispatchStore.allModels))

        let arguments = ProcessInfo.processInfo.arguments
        isTestEnvironment = arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        if isTestEnvironment,
           let uiTestingDefaults = UserDefaults(suiteName: "ui-testing") {
            uiTestingDefaults.removePersistentDomain(forName: "ui-testing")
            appDefaults = uiTestingDefaults
        } else {
            appDefaults = .standard
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

        let scheduler = NotificationScheduler(container: container, isTestEnvironment: isTestEnvironment)
        notificationScheduler = scheduler
        UNUserNotificationCenter.current().delegate = scheduler

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
                .environment(\.appDefaults, appDefaults)
                .environment(\.notificationPrefs, notificationPrefs)
                .onAppear {
                    if appDefaults.bool(forKey: OnboardingFlag.key) {
                        notificationScheduler.requestPermissionIfNeeded(prefs: notificationPrefs, awakeStore: awakeStore)
                    }
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if newPhase == .active {
                        notificationScheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
                        appLockStore.evaluateReturnFromBackground(backgroundedAt: backgroundedAt)
                        backgroundedAt = nil
                    } else if newPhase == .background {
                        backgroundedAt = Date()
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

    private func seedDefaultQuestionsIfNeeded() {
        let context = ModelContext(container)
        guard ((try? context.fetchCount(FetchDescriptor<Question>())) ?? 0) == 0 else { return }
        let defaults: [(String, QuestionType)] = [
            ("How did you sleep?", .multipleChoice),
            ("Are you working?", .yesNo),
            ("What are you doing?", .tokens),
            ("Where are you?", .location),
            ("Who are you with?", .people),
            ("How many coffees did you have today?", .number),
            ("What did you learn today?", .note),
        ]
        for (index, (prompt, type)) in defaults.enumerated() {
            let question = Question()
            question.uniqueIdentifier = "default-question-\(index)"
            question.prompt = prompt
            question.type = type
            question.sortOrder = index
            if prompt == "How did you sleep?" {
                question.reportKinds = [.wake]
                question.choices = ["Great", "OK", "Poorly"]
            }
            context.insert(question)
        }
        do {
            try context.save()
        } catch {
            seedLog.error("failed to seed default questions: \(error, privacy: .public)")
        }
    }
}
