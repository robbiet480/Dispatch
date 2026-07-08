import DispatchKit
import os
import SwiftData
import SwiftUI

private let seedLog = Logger(subsystem: "com.robbiet480.dispatch", category: "seed")

@main
struct DispatchApp: App {
    let container: ModelContainer
    let themeStore: ThemeStore
    let awakeStore: AwakeStore
    let surveyPresenter = SurveyPresenter()
    private let appDefaults: UserDefaults

    init() {
        container = try! ModelContainer(for: Schema(DispatchStore.allModels))

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mock-sensors") || arguments.contains("--ui-testing"),
           let uiTestingDefaults = UserDefaults(suiteName: "ui-testing") {
            uiTestingDefaults.removePersistentDomain(forName: "ui-testing")
            appDefaults = uiTestingDefaults
        } else {
            appDefaults = .standard
        }

        themeStore = ThemeStore(defaults: appDefaults)
        awakeStore = AwakeStore(defaults: appDefaults)

        seedDefaultQuestionsIfNeeded()
        if arguments.contains("--skip-onboarding") {
            appDefaults.set(true, forKey: OnboardingFlag.key)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(themeStore)
                .environment(awakeStore)
                .environment(surveyPresenter)
                .environment(\.appDefaults, appDefaults)
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
