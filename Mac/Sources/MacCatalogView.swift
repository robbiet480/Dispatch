import DispatchKit
import SwiftData
import SwiftUI

/// Plan 47 (issue #58): Mac question-catalog access — browse/search the
/// world-readable community catalog, add an entry to your questions, submit
/// your own, and flag inappropriate entries. Rides the shared, platform-clean
/// `CatalogStore`/`CatalogProvider` (dual target membership); the CloudKit
/// public database needs no new entitlements.
struct MacCatalogView: View {
    @Environment(\.modelContext) private var context
    @State private var store = CatalogStore()
    @State private var showingSubmit = false
    @State private var addedRecordNames: Set<String> = []
    @State private var flagging: CatalogQuestion?
    @State private var flagReason = ""
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            catalogSearchField
            content
        }
            .navigationTitle("Question Catalog")
            .toolbar {
                ToolbarItem {
                    Button {
                        showingSubmit = true
                    } label: {
                        Label("Submit", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("mac-catalog-submit")
                }
            }
            .sheet(isPresented: $showingSubmit) {
                MacCatalogSubmitView(store: store)
            }
            .alert("Flag this question?", isPresented: Binding(
                get: { flagging != nil }, set: { if !$0 { flagging = nil } }
            ), presenting: flagging) { entry in
                TextField("Reason (optional)", text: $flagReason)
                Button("Flag", role: .destructive) { submitFlag(entry) }
                Button("Cancel", role: .cancel) { flagging = nil }
            } message: { _ in
                Text("Flagged questions are reviewed by a moderator.")
            }
            .alert("Catalog", isPresented: Binding(
                get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } }
            ), presenting: statusMessage) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .task {
                if store.phase == .idle { await store.loadFirstPage() }
            }
    }

    /// In-content search field. This replaces a toolbar `.searchable`, which
    /// collided with the reports-list sidebar's `.searchable`: both split-view
    /// columns are alive at once, so both tried to add the single
    /// `com.apple.SwiftUI.search` item to the one window toolbar and AppKit
    /// threw NSInternalInconsistencyException — crashing the app when the
    /// catalog pane opened (shipped in build 30).
    private var catalogSearchField: some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search questions", text: $store.searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("mac-catalog-search")
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView().accessibilityIdentifier("mac-catalog-loading")
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.loadFirstPage() } }
            }
            .padding()
        case .loaded:
            if store.filteredEntries.isEmpty {
                Text(store.searchText.isEmpty
                     ? "No questions in the catalog yet. Be the first to submit one!"
                     : "No questions match your search.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .accessibilityIdentifier("mac-catalog-empty")
            } else {
                entryList
            }
        }
    }

    private var entryList: some View {
        List {
            ForEach(store.filteredEntries) { entry in
                MacCatalogRow(
                    entry: entry,
                    isAdded: addedRecordNames.contains(entry.recordName),
                    onAdd: { add(entry) },
                    onFlag: { flagReason = ""; flagging = entry })
            }
            if store.hasMore, store.searchText.isEmpty {
                Button {
                    Task { await store.loadNextPage() }
                } label: {
                    if store.isLoadingMore { ProgressView() } else { Text("Load more…") }
                }
                .accessibilityIdentifier("mac-catalog-load-more")
            }
        }
        .accessibilityIdentifier("mac-catalog-list")
    }

    private func add(_ entry: CatalogQuestion) {
        if store.addToMyQuestions(entry, context: context) != nil {
            statusMessage = "Added to your questions."
        } else {
            statusMessage = "This question is already in your list."
        }
        addedRecordNames.insert(entry.recordName)
    }

    private func submitFlag(_ entry: CatalogQuestion) {
        let recordName = entry.recordName
        let reason = flagReason
        flagging = nil
        Task {
            if case .unavailable(let why) = await store.accountStatus() {
                statusMessage = why
                return
            }
            do {
                try await store.flag(catalogRecordName: recordName, reason: reason)
                statusMessage = "Thanks — a moderator will take a look."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}

private struct MacCatalogRow: View {
    let entry: CatalogQuestion
    let isAdded: Bool
    let onAdd: () -> Void
    let onFlag: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt).font(.body).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isAdded ? "Added ✓" : "Add") { onAdd() }
                .disabled(isAdded)
                .accessibilityIdentifier("mac-catalog-add")
            Menu {
                Button("Flag…", role: .destructive) { onFlag() }
                    .accessibilityIdentifier("mac-catalog-flag")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var subtitle: String {
        var parts = [entry.type?.displayName ?? "Unknown type"]
        if let credit = entry.credit, !credit.isEmpty { parts.append("by \(credit)") }
        return parts.joined(separator: " · ")
    }
}
