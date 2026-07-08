import DispatchKit
import SwiftData
import SwiftUI

struct QuestionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]

    /// nil ⇒ creating a new question.
    let question: Question?

    @State private var prompt: String
    @State private var type: QuestionType
    @State private var choices: [String]
    @State private var placeholder: String
    @State private var kinds: Set<ReportKind>

    private var theme: Theme { ThemeStore().theme }

    init(question: Question?) {
        self.question = question
        _prompt = State(initialValue: question?.prompt ?? "")
        _type = State(initialValue: question?.type ?? .tokens)
        _choices = State(initialValue: question?.choices ?? [])
        _placeholder = State(initialValue: question?.placeholderString ?? "")
        _kinds = State(initialValue: Set(question?.reportKinds ?? [.regular]))
    }

    /// Existing questions cannot change type once responses reference them —
    /// changing shape would orphan already-recorded answers.
    private var isTypeLocked: Bool {
        guard let question else { return false }
        return responses.contains { response in
            response.questionIdentifier == question.uniqueIdentifier
                || response.questionPrompt == question.prompt
        }
    }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !kinds.isEmpty
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            Form {
                Section {
                    TextField("Prompt", text: $prompt)
                } header: {
                    sectionHeader("PROMPT")
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Picker("Type", selection: $type) {
                        ForEach(QuestionType.allCases, id: \.self) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    .disabled(isTypeLocked)
                } header: {
                    sectionHeader("TYPE")
                } footer: {
                    if isTypeLocked {
                        Text("Type is locked because this question already has responses.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .listRowBackground(Color.white.opacity(0.12))

                if type == .multipleChoice {
                    Section {
                        ForEach(Array(choices.enumerated()), id: \.offset) { index, _ in
                            HStack {
                                TextField("Choice", text: choiceBinding(index))
                                Button {
                                    choices.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        Button {
                            choices.append("")
                        } label: {
                            Label("Add choice", systemImage: "plus.circle.fill")
                        }
                    } header: {
                        sectionHeader("CHOICES")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                }

                Section {
                    TextField("Placeholder", text: $placeholder)
                } header: {
                    sectionHeader("PLACEHOLDER")
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    ForEach(ReportKind.allCases, id: \.self) { kind in
                        Button {
                            toggle(kind)
                        } label: {
                            HStack {
                                Text(kind.displayName)
                                    .foregroundStyle(.white)
                                Spacer()
                                if kinds.contains(kind) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                } header: {
                    sectionHeader("SHOW ON")
                } footer: {
                    Text("At least one report kind is required.")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(question == nil ? "Add Question" : "Edit Question")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private func choiceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { choices.indices.contains(index) ? choices[index] : "" },
            set: { newValue in if choices.indices.contains(index) { choices[index] = newValue } }
        )
    }

    private func toggle(_ kind: ReportKind) {
        if kinds.contains(kind) {
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
    }

    private func save() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedChoices = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let orderedKinds = ReportKind.allCases.filter { kinds.contains($0) }

        if let question {
            question.prompt = trimmedPrompt
            if !isTypeLocked {
                question.type = type
            }
            question.choices = question.type == .multipleChoice ? cleanedChoices : []
            question.placeholderString = trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder
            question.reportKinds = orderedKinds
        } else {
            let newQuestion = QuestionAdmin.makeQuestion(
                prompt: trimmedPrompt,
                type: type,
                choices: type == .multipleChoice ? cleanedChoices : [],
                placeholder: trimmedPlaceholder.isEmpty ? nil : trimmedPlaceholder,
                kinds: orderedKinds,
                after: questions
            )
            context.insert(newQuestion)
        }

        try? context.save()
        dismiss()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

extension ReportKind {
    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .wake: "Wake"
        case .sleep: "Sleep"
        }
    }
}
