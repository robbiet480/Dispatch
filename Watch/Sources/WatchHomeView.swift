import DispatchKit
import SwiftData
import SwiftUI

/// The watch home screen: the enabled question list (prompt-group order —
/// `sortOrder`, the same ordering the phone home list uses). Task 1
/// placeholder scope: a read-only list proving the store round-trips;
/// quick-answer and filing arrive with Task 4.
struct WatchHomeView: View {
    @Query(sort: \Question.sortOrder) private var questions: [Question]

    private var enabledQuestions: [Question] {
        questions.filter { $0.isEnabled && $0.reportKinds.contains(.regular) }
    }

    var body: some View {
        NavigationStack {
            List {
                if enabledQuestions.isEmpty {
                    Text("No questions yet. They sync from your iPhone.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-empty-state")
                } else {
                    ForEach(enabledQuestions, id: \.uniqueIdentifier) { question in
                        Text(question.prompt)
                            .lineLimit(3)
                    }
                }
            }
            .navigationTitle("Dispatch")
            .accessibilityIdentifier("watch-question-list")
        }
    }
}
