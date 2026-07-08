import DispatchKit
import SwiftUI

/// Sheet listing all enabled questions with visibility toggles, backed by
/// `VisualizationFilterStore`. Presented from Home's "Filter Visualizations…" pill.
struct VisualizationFilterView: View {
    let questions: [Question]
    let filterStore: VisualizationFilterStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    private var theme: Theme { themeStore.theme }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeBackground(theme)
                    .ignoresSafeArea()

                List {
                    ForEach(questions, id: \.uniqueIdentifier) { question in
                        Toggle(question.prompt, isOn: binding(for: question))
                            .foregroundStyle(.white)
                            .listRowBackground(Color.white.opacity(0.12))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("viz-filter-list")
            }
            .navigationTitle("Filter Visualizations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(.white)
                }
            }
        }
    }

    private func binding(for question: Question) -> Binding<Bool> {
        Binding(
            get: { filterStore.isVisible(question.uniqueIdentifier) },
            set: { filterStore.setVisible(question.uniqueIdentifier, $0) }
        )
    }
}
