import DispatchKit
import SwiftUI

/// Dedicated options editor for multiple-choice questions (plan 11, mirroring
/// the original Reporter): drag-reorder, swipe-delete, "ADD AN OPTION…" row,
/// and a MULTIPLE SELECTIONS Allowed/Not Allowed picker.
struct ChoiceOptionsEditorView: View {
    @Binding var choices: [String]
    @Binding var allowsMultipleSelection: Bool
    let theme: Theme

    /// One editable row per option. The stable UUID (NOT the array offset)
    /// keeps `.onMove`/ForEach identity intact across reorders and edits
    /// (build-5 review fix).
    private struct OptionRow: Identifiable {
        let id: UUID
        var text: String
    }

    @State private var rows: [OptionRow]

    /// Live keystrokes for the new-option row stay in local @State — never
    /// routed through an observable per keystroke (see LocalTextEditorField's
    /// doc comment in QuestionPageView for the keyboard-garbling lesson).
    @State private var newOption = ""
    @SwiftUI.FocusState private var addFieldFocused: Bool

    init(choices: Binding<[String]>, allowsMultipleSelection: Binding<Bool>, theme: Theme) {
        _choices = choices
        _allowsMultipleSelection = allowsMultipleSelection
        self.theme = theme
        _rows = State(initialValue: choices.wrappedValue.map { OptionRow(id: UUID(), text: $0) })
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    ForEach(rows) { row in
                        ChoiceOptionField(text: row.text, placeholder: "Option") { newText in
                            commitEdit(id: row.id, text: newText)
                        }
                    }
                    .onMove { source, destination in
                        rows.move(fromOffsets: source, toOffset: destination)
                        syncBack()
                    }
                    .onDelete { offsets in
                        rows.remove(atOffsets: offsets)
                        syncBack()
                    }

                    TextField("Add an option…", text: $newOption)
                        .focused($addFieldFocused)
                        .onSubmit(commitNewOption)
                        .submitLabel(.done)
                        .accessibilityIdentifier("add-option")
                } header: {
                    header("CHOICES")
                } footer: {
                    Text("Tap an option to edit it. Drag to reorder. Swipe to delete.")
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))

                Section {
                    Picker("Multiple Selections", selection: $allowsMultipleSelection) {
                        Text("Allowed").tag(true)
                        Text("Not Allowed").tag(false)
                    }
                    .accessibilityIdentifier("multiple-selections")
                } header: {
                    header("MULTIPLE SELECTIONS")
                } footer: {
                    Text("When not allowed, picking an option replaces the previous selection.")
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle("Choices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // Edit mode enables drag-reorder handles; swipe-delete works in
            // the default mode as well.
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onDisappear(perform: commitNewOption)
        .accessibilityIdentifier("choice-options-editor")
    }

    private func commitNewOption() {
        let trimmed = newOption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rows.append(OptionRow(id: UUID(), text: trimmed))
        newOption = ""
        syncBack()
    }

    /// Commits an in-place edit; an emptied field keeps the old text
    /// (ChoiceOptionField already reverts its draft in that case).
    private func commitEdit(id: UUID, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
        syncBack()
    }

    private func syncBack() {
        choices = rows.map(\.text)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

/// In-place option editor row. Keystrokes stay in the local draft (the
/// LocalTextEditorField discipline); the edit commits on submit, focus loss
/// (tapping another row, dismissing the keyboard), or row disappearance —
/// Return-only commits silently dropped edits (gating review fix). An
/// emptied field reverts to the old text instead of committing.
private struct ChoiceOptionField: View {
    let text: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var draft: String
    @SwiftUI.FocusState private var isFocused: Bool

    init(text: String, placeholder: String, onCommit: @escaping (String) -> Void) {
        self.text = text
        self.placeholder = placeholder
        self.onCommit = onCommit
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .foregroundStyle(.white)
            .submitLabel(.done)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = text // empty keeps the old option
        } else {
            draft = trimmed
            onCommit(trimmed)
        }
    }
}

extension VisualizationStyle {
    var displayName: String {
        switch self {
        case .proportion: "Proportion"
        case .graph: "Graph"
        case .frequency: "Frequency"
        }
    }
}
