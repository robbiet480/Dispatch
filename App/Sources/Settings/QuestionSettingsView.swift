import DispatchKit
import SwiftData
import SwiftUI

struct QuestionSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]
    @Environment(ThemeStore.self) private var themeStore

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                ForEach(questions, id: \.uniqueIdentifier) { question in
                    QuestionRowView(question: question, responseCount: responseCount(for: question))
                        .listRowBackground(Color.white.opacity(0.12))
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                NavigationLink(destination: QuestionEditorView(question: nil)) {
                    Text("ADD A QUESTION…")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
                .listRowBackground(Color.white.opacity(0.12))
                .accessibilityIdentifier("add-question-button")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
            .accessibilityIdentifier("question-settings-list")
        }
        .navigationTitle("Questions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(destination: CatalogView()) {
                    Image(systemName: "books.vertical")
                }
                .tint(.white)
                .accessibilityLabel("Question Catalog")
                .accessibilityIdentifier("question-catalog-link")

                EditButton()
                    .tint(.white)
            }
        }
    }

    private func responseCount(for question: Question) -> Int {
        responses.count { response in
            if let responseQuestionIdentifier = response.questionIdentifier {
                return responseQuestionIdentifier == question.uniqueIdentifier
            }
            // Legacy imports have no questionIdentifier — fall back to prompt equality.
            return response.questionPrompt == question.prompt
        }
    }

    private func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = questions
        QuestionAdmin.move(&reordered, fromOffsets: fromOffsets, toOffset: toOffset)
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        // Responses are left untouched — they join back by prompt/identifier.
        for offset in offsets {
            context.delete(questions[offset])
        }
        try? context.save()
    }
}

struct QuestionRowView: View {
    let question: Question
    let responseCount: Int

    var body: some View {
        NavigationLink(destination: QuestionEditorView(question: question)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.prompt.uppercased())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(question.type.displayName) – \(responseCount) responses")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(.white.opacity(0.4))
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { question.isEnabled },
            set: { question.isEnabled = $0; try? question.modelContext?.save() }
        )
    }
}

// QuestionType.displayName moved to DispatchKit (QuestionDisplay.swift,
// plan 47) so the iOS and macOS surfaces share one definition.
