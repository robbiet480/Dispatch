import DispatchKit
import SwiftData
import SwiftUI

/// The watch home screen (plan 19 v1): quick-answer front and center, then
/// the enabled-question list (sortOrder, the phone home ordering), then
/// Settings. No drafts, editing, or visualizations — file-and-done.
struct WatchHomeView: View {
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Environment(\.modelContext) private var modelContext

    @State private var quickAnswerState: FilingState = .idle
    @State private var quickAnswerTask: Task<Void, Never>?

    enum FilingState: Equatable {
        case idle, filing, filed
    }

    private var enabledQuestions: [Question] {
        questions.filter { $0.isEnabled && $0.reportKinds.contains(.regular) }
    }

    /// Same eligibility as the widget/notification quick answer.
    private var quickAnswerQuestion: Question? {
        QuickAnswerFiler.firstEnabledYesNoQuestion(in: modelContext)
    }

    var body: some View {
        NavigationStack {
            List {
                if let question = quickAnswerQuestion {
                    quickAnswerSection(question)
                }
                questionsSection
                Section {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("watch-settings-link")
                }
            }
            .navigationTitle("Dispatch")
            .accessibilityIdentifier("watch-question-list")
        }
        .onDisappear { quickAnswerTask?.cancel() }
    }

    private func quickAnswerSection(_ question: Question) -> some View {
        Section {
            Text(question.prompt)
                .font(.headline)
                .lineLimit(3)
            switch quickAnswerState {
            case .filing:
                HStack {
                    ProgressView()
                    Text("Filing…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Filing report")
            case .filed:
                Label("Filed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("watch-quick-answer-filed")
            case .idle:
                HStack(spacing: 8) {
                    quickAnswerButton(question, index: 0, fallback: "Yes")
                    quickAnswerButton(question, index: 1, fallback: "No")
                }
            }
        } header: {
            Text("Quick Answer")
        }
    }

    private func quickAnswerButton(_ question: Question, index: Int, fallback: String) -> some View {
        let title = question.choices.indices.contains(index) ? question.choices[index] : fallback
        return Button(title) {
            quickAnswer(question: question, choiceIndex: index)
        }
        .buttonStyle(.borderedProminent)
        .tint(index == 0 ? .green : .red)
        .accessibilityIdentifier(index == 0 ? "watch-quick-answer-yes" : "watch-quick-answer-no")
        .accessibilityLabel("\(title): \(question.prompt)")
    }

    private var questionsSection: some View {
        Section {
            if enabledQuestions.isEmpty {
                Text("No questions yet. They sync from your iPhone.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch-empty-state")
            } else {
                ForEach(enabledQuestions, id: \.uniqueIdentifier) { question in
                    NavigationLink {
                        WatchQuestionView(question: question)
                    } label: {
                        Text(question.prompt)
                            .lineLimit(3)
                    }
                }
            }
        } header: {
            Text("Questions")
        }
    }

    private func quickAnswer(question: Question, choiceIndex: Int) {
        guard quickAnswerState == .idle else { return }
        quickAnswerState = .filing
        let context = modelContext
        quickAnswerTask = Task {
            do {
                let report = try await WatchReportFiler.fileQuickAnswer(
                    question: question, choiceIndex: choiceIndex, in: context
                )
                quickAnswerState = report == nil ? .idle : .filed
                if report != nil {
                    WatchWidgetRefresher.reload()
                }
            } catch {
                watchFilingLog.error("quick answer failed: \(error, privacy: .public)")
                quickAnswerState = .idle
            }
            // Let the checkmark breathe, then re-arm for the next answer.
            try? await Task.sleep(for: .seconds(3))
            if quickAnswerState == .filed { quickAnswerState = .idle }
        }
    }
}
