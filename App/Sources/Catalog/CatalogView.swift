import DispatchKit
import SwiftData
import SwiftUI

/// iPhone / compact host for the catalog: the shared `CatalogListView` in a
/// NavigationStack that pushes `CatalogDetailView`. Also used as the interim
/// Mac catalog pane until the shared shell lands (Sprint 3).
struct CatalogView: View {
    @State private var store = CatalogStore()
    @State private var selection: CatalogQuestion.ID?
    @State private var showingSubmit = false

    var body: some View {
        // No NavigationStack of its own. On iPhone this view is ALWAYS pushed
        // into an ambient stack — from Settings' "Manage" section, or from
        // `QuestionSettingsView`'s "QUESTION CATALOG…" row — so wrapping it in a
        // second, nested stack made the detail push land in the inner stack
        // while the list's back button popped the outer one. A double-back-tap
        // (detail → list → questions) then hit two different navigation bars and
        // could momentarily find none (Task 3.9). Relying on the ambient stack
        // keeps list → detail → back one consistent hierarchy. The iPad/Mac
        // shell hosts `CatalogListView` directly and never uses `CatalogView`.
        CatalogListView(store: store, selection: $selection) { showingSubmit = true }
            .navigationTitle("Question Catalog")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .navigationDestination(item: detailBinding) { entry in
                CatalogDetailView(entry: entry, store: store)
            }
            .sheet(isPresented: $showingSubmit) { CatalogSubmitView(store: store) }
    }

    /// Maps the id selection to the entry so `navigationDestination(item:)`
    /// pushes the detail and a pop clears the selection.
    private var detailBinding: Binding<CatalogQuestion?> {
        Binding(
            get: { store.filteredEntries.first { $0.id == selection } },
            set: { selection = $0?.id })
    }
}

// MARK: - Detail

struct CatalogDetailView: View {
    let entry: CatalogQuestion
    let store: CatalogStore

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Task 3.8: suppresses this view's own title when hosted in
    /// `LargeScreenShell`, where the pane picker is the sole title. Default
    /// false preserves the title when pushed from iPhone's `CatalogView`.
    @Environment(\.isInLargeScreenShell) private var inShell

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
                    Text(entry.prompt.uppercased())
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
        .navigationTitle(inShell ? "" : "Catalog Question")
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
        // Scroll horizontally so a long tag list never clips at narrow widths.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { tag in
                    Text(tag).font(.caption2)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(.white)
                }
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
        // Format directly — `Int(v)` traps when `configSummary` passes a
        // stepper/tapCounter config's `.greatestFiniteMagnitude` "no max"
        // bound (same poison-pill class as the preview's A1 fix).
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}
