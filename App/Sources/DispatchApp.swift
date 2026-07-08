import DispatchKit
import os
import SwiftData
import SwiftUI

private let seedLog = Logger(subsystem: "com.robbiet480.dispatch", category: "seed")

@main
struct DispatchApp: App {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: Schema(DispatchStore.allModels))
        seedDefaultQuestionsIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
