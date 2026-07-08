import DispatchKit
import SwiftData
import SwiftUI

struct CustomTokensView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TokenEntity.text) private var tokens: [TokenEntity]

    private var theme: Theme { ThemeStore().theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    ForEach(tokens, id: \.text) { token in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(token.text)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                            Text("Used \(token.usageCount) times in \(token.questionCount) questions")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .listRowBackground(Color.white.opacity(0.12))
                    }
                    .onDelete(perform: delete)
                } header: {
                    sectionHeader("\(tokens.count) TOKENS")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Custom Tokens")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func delete(at offsets: IndexSet) {
        // Removes vocabulary entries only — recorded responses are untouched.
        for offset in offsets {
            context.delete(tokens[offset])
        }
        try? context.save()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}
