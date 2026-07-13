import DispatchKit
import SwiftData
import SwiftUI

/// The reusable, themed list of questions. Selection-based (like
/// `CatalogListView`) so the same view is BOTH a push-list — iPhone/Settings,
/// wrapped by `QuestionSettingsView` in an ambient `NavigationStack` with a
/// `.navigationDestination(item:)` that pushes the editor — AND, once the
/// Sprint-3 shell lands, a split-view sidebar whose selection drives a
/// `QuestionEditorView` in the adjacent detail column.
///
/// Rows are tagged by `question.uniqueIdentifier` and participate in
/// `List(selection:)`; the enclosing host owns what a selection means (push vs
/// detail column). Carries the Task 2.3 Mac affordances (file-picker
/// import/export + the delete-confirmation dialog) behind `#if os(macOS)`.
struct QuestionsList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @Query private var responses: [Response]
    @Environment(ThemeStore.self) private var themeStore
    #if os(macOS)
    // Task 2.3 (iPad/Mac UI convergence): the Mac file-picker question
    // import/export lives on `MacExportController` (NSOpenPanel/NSSavePanel
    // driven) — no iOS equivalent, so it's wired in here behind an os
    // guard rather than dropped when this view replaced `MacQuestionsView`.
    @Environment(MacExportController.self) private var exportController
    @State private var pendingDelete: Question?
    #endif

    /// The selected question's `uniqueIdentifier`, owned by the host. The host
    /// decides what a selection means: `QuestionSettingsView` pushes the editor
    /// via `.navigationDestination(item:)`; the future shell shows it in a
    /// detail column.
    @Binding var selection: String?

    init(selection: Binding<String?>) {
        _selection = selection
    }

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            // SwiftUI keeps only the LAST `.accessibilityIdentifier` applied to
            // a given view, so the two ids are split across the `List` and an
            // enclosing `Group` (the proven CatalogListView pattern). This List
            // now carries a `selection:` binding, so — unlike the pre-3.2
            // version — the Mac screenshot id sits DIRECTLY on the `List`
            // (MacCatalogUITests proves a List-level id survives AppKit's
            // AXOutline translation); the iOS-test id lives on the `Group`.
            Group {
                List(selection: $selection) {
                    ForEach(questions, id: \.uniqueIdentifier) { question in
                        QuestionRowView(question: question, responseCount: responseCount(for: question))
                            .tag(question.uniqueIdentifier)
                            .listRowBackground(Color.white.opacity(0.12))
                            #if os(macOS)
                            // Mac-only safety net: MacQuestionsView offered a
                            // confirmation dialog before deleting a question;
                            // the shared list's swipe/edit-mode delete (below)
                            // has no confirmation, so this stays desktop-only.
                            .contextMenu {
                                Button("Delete", role: .destructive) { pendingDelete = question }
                            }
                            #endif
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

                    NavigationLink(destination: CatalogView()) {
                        Text("QUESTION CATALOG…")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("question-catalog-link")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Plan 27: readable column on iPad; no-op at iPhone widths.
                .readableColumn()
                .accessibilityIdentifier("mac-questions-list")
            }
            .accessibilityIdentifier("question-settings-list")
        }
        .navigationTitle("Questions")
        .inlineNavTitleOnPhone()
        .darkNavBarOnPhone()
        .toolbar {
            // `EditButton` doesn't exist on macOS — its List already
            // supports drag-reorder/delete without an edit-mode toggle (the
            // pattern the retired MacQuestionsView shipped with, plus the
            // context-menu delete confirmation below), so this is iOS-only,
            // not a dropped capability.
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
                    .tint(.white)
            }
            #endif
            #if os(macOS)
            ToolbarItem {
                Button {
                    exportController.importQuestions(existingPrompts: questions.map(\.prompt))
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("mac-questions-import")
            }
            ToolbarItem {
                Menu {
                    Button("CSV…") { exportController.exportQuestionsCSV() }
                    Button("JSON…") { exportController.exportQuestionsJSON() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("mac-questions-export")
            }
            #endif
        }
        #if os(macOS)
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
        #endif
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

/// iPhone / Settings push-host over `QuestionsList`. Reached via a
/// `NavigationLink` from `SettingsView` (iPhone) and wrapped in
/// `NavigationStack { QuestionSettingsView() }` by `MacRootView` (Mac), so it
/// deliberately does NOT create its own `NavigationStack` — it relies on that
/// ambient stack and registers a `.navigationDestination(item:)` that pushes
/// the editor for the selected question. The "add a question" / "catalog" rows
/// keep their own `NavigationLink` pushes (see `QuestionsList`). Same entry
/// point and same user-visible behavior as before Task 3.2.
struct QuestionSettingsView: View {
    @Query(sort: \Question.sortOrder) private var questions: [Question]
    @State private var selection: String?

    var body: some View {
        QuestionsList(selection: $selection)
            .navigationDestination(item: $selection) { identifier in
                // A selection can outlive its question (deleted while selected);
                // guard the lookup so a stale id never opens the new-question
                // editor (`QuestionEditorView(question: nil)`).
                if let question = questions.first(where: { $0.uniqueIdentifier == identifier }) {
                    QuestionEditorView(question: question)
                }
            }
    }
}

struct QuestionRowView: View {
    let question: Question
    let responseCount: Int

    var body: some View {
        // Plain, selectable row content — no `NavigationLink`. Navigation is
        // driven by the enclosing `List(selection:)` + the host's
        // `.navigationDestination(item:)` (Task 3.2), which lets the same row
        // act as a push on iPhone and a detail-column selection in the shell.
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.prompt.uppercased())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(question.type.displayName) – \(responseCount) response\(responseCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .tint(.white.opacity(0.4))
                #if os(macOS)
                .accessibilityIdentifier("mac-question-enabled-\(question.uniqueIdentifier)")
                #endif
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
