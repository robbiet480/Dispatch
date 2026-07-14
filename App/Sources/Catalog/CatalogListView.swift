import DispatchKit
import SwiftUI

/// Shared, themed catalog list. Selection-based so the same view is a
/// push-list (iPhone, wrapped in a NavigationStack with a navigationDestination)
/// and a shell sidebar (iPad/Mac). Search is an in-content field — never a
/// toolbar `.searchable`, which crashes when two split columns are live.
struct CatalogListView: View {
    let store: CatalogStore
    @Binding var selection: CatalogQuestion.ID?
    var onSubmit: () -> Void

    @Environment(ThemeStore.self) private var themeStore
    private var theme: Theme { themeStore.theme }

    var body: some View {
        @Bindable var store = store
        ZStack {
            Color.themeBackground(theme).ignoresSafeArea()
            VStack(spacing: 0) {
                searchField(store: store)
                content(store: store)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onSubmit) {
                    Label("Submit a Question", systemImage: "plus")
                }
                .tint(.white)
                .accessibilityIdentifier("catalog-submit-button")
            }
        }
        .task { if store.phase == .idle { await store.loadFirstPage() } }
    }

    private func searchField(store: CatalogStore) -> some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField("Search questions", text: $store.searchText)
                .textFieldStyle(.plain).foregroundStyle(.white)
                .accessibilityIdentifier("catalog-search")
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.borderless).accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    @ViewBuilder private func content(store: CatalogStore) -> some View {
        switch store.phase {
        case .idle, .loading:
            Spacer(); ProgressView().tint(.white).accessibilityIdentifier("catalog-loading"); Spacer()
        case .failed(let message):
            Spacer()
            VStack(spacing: 12) {
                Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Button("Try Again") { Task { await store.loadFirstPage() } }.foregroundStyle(.white).fontWeight(.semibold)
            }.padding().accessibilityIdentifier("catalog-error")
            Spacer()
        case .loaded:
            if store.filteredEntries.isEmpty {
                Spacer()
                Text(store.searchText.isEmpty
                     ? "No questions in the catalog yet. Be the first to submit one!"
                     : "No questions match your search.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding()
                    .accessibilityIdentifier("catalog-empty")
                Spacer()
            } else {
                list(store: store)
            }
        }
    }

    // SwiftUI keeps only the LAST `.accessibilityIdentifier` applied to a
    // given view — applying both `question-catalog-list` (iOS UI test) and
    // `mac-catalog-list` (Mac screenshot suite) to the `List` itself would
    // silently drop the first. Split them across the `List` and an
    // enclosing `Group` so both resolve.
    private func list(store: CatalogStore) -> some View {
        Group {
            List(selection: $selection) {
                ForEach(store.filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        // Uppercased for visual parity with the original iOS
                        // catalog list (and `QuestionRowView`) — the shared
                        // list dropped it in the Sprint 1 refactor. The
                        // transform also flows into the accessibility label, so
                        // UI tests match the row by its uppercased prompt.
                        Text(entry.prompt.uppercased()).font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.white).lineLimit(2)
                        Text(subtitle(entry)).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .tag(entry.id)
                    .listRowBackground(Color.white.opacity(0.12))
                }
                if store.hasMore, store.searchText.isEmpty {
                    Button { Task { await store.loadNextPage() } } label: {
                        if store.isLoadingMore { ProgressView().tint(.white) }
                        else { Text("LOAD MORE…").font(.subheadline).fontWeight(.semibold).foregroundStyle(.white) }
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("catalog-load-more")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .readableColumn()
            .accessibilityIdentifier("mac-catalog-list")
        }
        .accessibilityIdentifier("question-catalog-list")
    }

    private func subtitle(_ entry: CatalogQuestion) -> String {
        var parts = [entry.type?.displayName ?? "Unknown type"]
        if let credit = entry.credit, !credit.isEmpty { parts.append("by \(credit)") }
        return parts.joined(separator: " · ")
    }
}
