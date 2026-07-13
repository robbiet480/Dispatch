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
                        .font(.title3).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.white.opacity(0.12))

                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.white.opacity(0.12))

                    if !entry.tags.isEmpty {
                        tagChips
                            .listRowBackground(Color.white.opacity(0.12))
                    }

                    if let summary = configSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .listRowBackground(Color.white.opacity(0.12))
                    }
                }

                Section {
                    QuestionInputPreviewView(control: QuestionInputPreview.control(for: entry))
                        .padding(.vertical, 4)
                        .listRowBackground(Color.white.opacity(0.12))
                } header: {
                    Text("PREVIEW")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.8))
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
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

    private var metadataLine: String {
        var parts = [entry.type?.displayName ?? "Unknown type"]
        if let credit = entry.credit, !credit.isEmpty { parts.append("by \(credit)") }
        parts.append(entry.approvedAt.formatted(.dateTime.month().year()))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var tagChips: some View {
        HStack(spacing: 6) {
            ForEach(entry.tags, id: \.self) { tag in
                Text(tag).font(.caption2)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    /// One-line "what you'll get" summary; nil when the preview already says it all.
    private var configSummary: String? {
        switch entry.type {
        case .multipleChoice:
            return entry.choices.isEmpty ? nil : "\(entry.choices.count) options"
        case .number:
            let style = entry.inputStyle.flatMap(NumberInputStyle.init(rawValue:)) ?? .textField
            let cfg = NumberInputStyle.resolvedConfig(for: style, min: entry.inputMin, max: entry.inputMax, step: entry.inputStep)
            if style == .textField { return "Number entry" }
            return "\(style.displayName) · \(trimmed(cfg.min))–\(trimmed(cfg.max)) step \(trimmed(cfg.step))"
        case .note:
            return entry.placeholder.map { "Free text · \u{201C}\($0)\u{201D}" }
        default:
            return nil
        }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
