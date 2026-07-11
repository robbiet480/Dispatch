import DispatchKit
import SwiftData
import SwiftUI

/// Plan 47 (issue #57): Mac question management — create/edit/reorder/
/// enable/disable/delete questions, plus CSV/JSON definition import & export.
/// Native Mac Form/List styling (not the iOS dark-themed background) — this is
/// the setup surface the big-keyboard device is for.
struct MacQuestionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(MacExportController.self) private var exportController
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]

    @State private var editingQuestion: Question?
    @State private var isCreating = false
    @State private var pendingDelete: Question?

    var body: some View {
        List {
            if questions.isEmpty {
                Text("No questions yet. Add one, or import a CSV/JSON file.")
                    .foregroundStyle(.secondary)
            }
            ForEach(questions, id: \.uniqueIdentifier) { question in
                MacQuestionRow(question: question,
                               responseCount: responseCount(for: question)) {
                    editingQuestion = question
                }
                .contextMenu {
                    Button("Edit…") { editingQuestion = question }
                    Button("Delete", role: .destructive) { pendingDelete = question }
                }
            }
            .onMove(perform: move)
            .onDelete(perform: delete)
        }
        .accessibilityIdentifier("mac-questions-list")
        .navigationTitle("Questions")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isCreating = true
                } label: {
                    Label("Add Question", systemImage: "plus")
                }
                .accessibilityIdentifier("mac-add-question")

                Button {
                    exportController.importQuestions(existingPrompts: questions.map(\.prompt))
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("mac-questions-import")

                Menu {
                    Button("CSV…") { exportController.exportQuestionsCSV() }
                    Button("JSON…") { exportController.exportQuestionsJSON() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("mac-questions-export")
            }
        }
        .sheet(isPresented: $isCreating) {
            MacQuestionEditorView(question: nil)
        }
        .sheet(item: $editingQuestion) { question in
            MacQuestionEditorView(question: question)
        }
        .sheet(isPresented: Binding(
            get: { exportController.showingQuestionImport },
            set: { exportController.showingQuestionImport = $0 }
        )) {
            if let plan = exportController.questionImportPlan {
                MacQuestionImportSheet(plan: plan) {
                    exportController.commitQuestionImport(into: context)
                }
            }
        }
        .confirmationDialog(
            "Delete this question?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { question in
            Button("Delete", role: .destructive) {
                context.delete(question)
                try? context.save()
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { question in
            Text("“\(question.prompt)” will be removed. Filed answers are kept.")
        }
    }

    private func responseCount(for question: Question) -> Int {
        responses.count { response in
            if let identifier = response.questionIdentifier {
                return identifier == question.uniqueIdentifier
            }
            return response.questionPrompt == question.prompt
        }
    }

    private func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = questions
        QuestionAdmin.move(&reordered, fromOffsets: fromOffsets, toOffset: toOffset)
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        for offset in offsets {
            context.delete(questions[offset])
        }
        try? context.save()
    }
}

private struct MacQuestionRow: View {
    @Bindable var question: Question
    let responseCount: Int
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.prompt.isEmpty ? "Untitled question" : question.prompt)
                    .font(.body)
                    .lineLimit(2)
                Text("\(question.type.displayName) · \(responseCount) response\(responseCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { onEdit() }
                .buttonStyle(.borderless)
            Toggle("Enabled", isOn: Binding(
                get: { question.isEnabled },
                set: { question.isEnabled = $0; try? question.modelContext?.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityIdentifier("mac-question-enabled-\(question.uniqueIdentifier)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }
}
