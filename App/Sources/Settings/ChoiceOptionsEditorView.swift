import DispatchKit
import SwiftUI

/// Dedicated options editor for multiple-choice questions (plan 11, mirroring
/// the original Reporter): drag-reorder, swipe-delete, "ADD AN OPTION…" row,
/// and a MULTIPLE SELECTIONS Allowed/Not Allowed picker.
struct ChoiceOptionsEditorView: View {
    @Binding var choices: [String]
    @Binding var allowsMultipleSelection: Bool
    let theme: Theme

    /// Live keystrokes for the new-option row stay in local @State — never
    /// routed through an observable per keystroke (see LocalTextEditorField's
    /// doc comment in QuestionPageView for the keyboard-garbling lesson).
    @State private var newOption = ""
    @SwiftUI.FocusState private var addFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Text(choice.isEmpty ? "Option \(index + 1)" : choice)
                            .foregroundStyle(.white)
                    }
                    .onMove { source, destination in
                        choices.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        choices.remove(atOffsets: offsets)
                    }

                    TextField("Add an option…", text: $newOption)
                        .focused($addFieldFocused)
                        .onSubmit(commitNewOption)
                        .submitLabel(.done)
                        .accessibilityIdentifier("add-option")
                } header: {
                    header("CHOICES")
                } footer: {
                    Text("Drag to reorder. Swipe to delete.")
                        .foregroundStyle(.white.opacity(0.7))
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
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .scrollContentBackground(.hidden)
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
        choices.append(trimmed)
        newOption = ""
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
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
