import DispatchKit
import os
import SwiftData
import SwiftUI
import UserNotifications

private let seedLog = Logger(subsystem: "com.robbiet480.dispatch", category: "seed")

@main
struct DispatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let container: ModelContainer
    let themeStore: ThemeStore
    let awakeStore: AwakeStore
    let notificationPrefs: NotificationPrefs
    let surveyPresenter = SurveyPresenter()
    let notificationScheduler: NotificationScheduler
    private let appDefaults: UserDefaults
    private let isTestEnvironment: Bool

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
                .environment(surveyPresenter)
                .environment(notificationScheduler)
                .environment(\.appDefaults, appDefaults)
                .environment(\.notificationPrefs, notificationPrefs)
                .onAppear {
                    if appDefaults.bool(forKey: OnboardingFlag.key) {
                        notificationScheduler.requestPermissionIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    notificationScheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
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
