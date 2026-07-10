import DispatchKit
import SwiftData
import SwiftUI

/// Community question catalog: browse approved entries from the public
/// CloudKit database, add one to your local questions, submit your own, or
/// flag an entry. Browsing works without an iCloud account; submitting and
/// flagging need one and explain themselves when it's missing.
struct CatalogView: View {
    @Environment(ThemeStore.self) private var themeStore
    @State private var store = CatalogStore()
    @State private var showingSubmitForm = false

    private var theme: Theme { themeStore.theme }

    var body: some View {
        @Bindable var store = store
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            content
        }
        .navigationTitle("Question Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Submit") { showingSubmitForm = true }
                    .tint(.white)
                    .accessibilityIdentifier("catalog-submit-button")
            }
        }
        .searchable(text: $store.searchText, prompt: "Search questions")
        .sheet(isPresented: $showingSubmitForm) {
            CatalogSubmitView(store: store)
        }
        .task {
            if store.phase == .idle {
                await store.loadFirstPage()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .accessibilityIdentifier("catalog-loading")
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await store.loadFirstPage() }
                }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            }
            .padding()
            .accessibilityIdentifier("catalog-error")
        case .loaded:
            if store.filteredEntries.isEmpty {
                Text(store.searchText.isEmpty
                    ? "No questions in the catalog yet. Be the first to submit one!"
                    : "No questions match your search.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding()
                    .accessibilityIdentifier("catalog-empty")
            } else {
                entryList
            }
        }
    }

    private var entryList: some View {
        List {
            ForEach(store.filteredEntries) { entry in
                NavigationLink(destination: CatalogDetailView(entry: entry, store: store)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.prompt.uppercased())
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitle(for: entry))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .listRowBackground(Color.white.opacity(0.12))
            }

            if store.hasMore, store.searchText.isEmpty {
                Button {
                    Task { await store.loadNextPage() }
                } label: {
                    if store.isLoadingMore {
                        ProgressView().tint(.white)
                    } else {
                        Text("LOAD MORE…")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                }
                .listRowBackground(Color.white.opacity(0.12))
                .accessibilityIdentifier("catalog-load-more")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Plan 27: readable column on iPad; no-op at iPhone widths.
        .readableColumn()
        .accessibilityIdentifier("question-catalog-list")
    }

    private func subtitle(for entry: CatalogQuestion) -> String {
        var parts = [entry.type?.displayName ?? "Unknown type"]
        if let credit = entry.credit, !credit.isEmpty {
            parts.append("by \(credit)")
        }
        return parts.joined(separator: " – ")
    }
}

// MARK: - Detail

struct CatalogDetailView: View {
    let entry: CatalogQuestion
    let store: CatalogStore

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showingFlagForm = false
    @State private var flagReason = ""
    @State private var statusMessage: String?
    @State private var added = false

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    Text(entry.prompt)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.white.opacity(0.12))

                    HStack {
                        Text("Type")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(entry.type?.displayName ?? "Unknown")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.white.opacity(0.12))

                    if !entry.choices.isEmpty {
                        ForEach(entry.choices, id: \.self) { choice in
                            Text(choice)
                                .foregroundStyle(.white.opacity(0.8))
                                .listRowBackground(Color.white.opacity(0.12))
                        }
                    }

                    if let credit = entry.credit, !credit.isEmpty {
                        HStack {
                            Text("Submitted by")
                                .foregroundStyle(.white)
                            Spacer()
                            Text(credit)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .listRowBackground(Color.white.opacity(0.12))
                    }
                }

                Section {
                    Button {
                        addToMyQuestions()
                    } label: {
                        Text(added ? "ADDED ✓" : "ADD TO MY QUESTIONS")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .disabled(added)
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("catalog-add-button")
                }

                Section {
                    Button {
                        showingFlagForm = true
                    } label: {
                        Text("Flag this question")
                            .font(.subheadline)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("catalog-flag-button")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .listRowBackground(Color.white.opacity(0.12))
                            .accessibilityIdentifier("catalog-detail-status")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle("Catalog Question")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert("Flag this question?", isPresented: $showingFlagForm) {
            TextField("Reason (optional)", text: $flagReason)
            Button("Flag", role: .destructive) { submitFlag() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flagged questions are reviewed by a moderator.")
        }
    }

    private func addToMyQuestions() {
        if store.addToMyQuestions(entry, context: context) != nil {
            added = true
            statusMessage = "Added to your questions."
        } else {
            added = true
            statusMessage = "This question is already in your list."
        }
    }

    private func submitFlag() {
        let entryRecordName = entry.recordName
        let reason = flagReason
        Task {
            do {
                if case .unavailable(let why) = await store.accountStatus() {
                    statusMessage = why
                    return
                }
                try await store.flag(catalogRecordName: entryRecordName, reason: reason)
                statusMessage = "Thanks — a moderator will take a look."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
