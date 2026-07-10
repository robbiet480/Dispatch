import DispatchKit
import Foundation
import Observation
import SwiftData

/// View-facing state for the community question catalog. All CloudKit work
/// happens inside the provider off the main actor; this store only holds
/// results. Search is client-side over the loaded entries (catalog scale is
/// small; avoids requiring a SEARCHABLE Console index on `prompt`).
@Observable
@MainActor
final class CatalogStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var entries: [CatalogQuestion] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    var searchText = ""

    private let provider: any CatalogProviding
    private var cursor: CatalogQueryCursor?

    var hasMore: Bool { cursor != nil }

    init(provider: any CatalogProviding = CatalogStore.makeProvider()) {
        self.provider = provider
    }

    /// Stubbed under UI-test launch args — UI tests never touch real CloudKit.
    static func makeProvider() -> any CatalogProviding {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") || arguments.contains("--mock-sensors") {
            return StubCatalogProvider()
        }
        return CloudKitCatalogProvider()
    }

    var filteredEntries: [CatalogQuestion] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.prompt.localizedCaseInsensitiveContains(query)
                || $0.tags.contains { tag in tag.localizedCaseInsensitiveContains(query) }
        }
    }

    func loadFirstPage() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let (entries, cursor) = try await provider.approvedQuestions(after: nil)
            self.entries = entries
            self.cursor = cursor
            phase = .loaded
        } catch {
            entries = []
            cursor = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func loadNextPage() async {
        guard let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let (more, nextCursor) = try await provider.approvedQuestions(after: cursor)
            // Dedupe on recordName in case a page boundary shifted server-side.
            let known = Set(entries.map(\.recordName))
            entries.append(contentsOf: more.filter { !known.contains($0.recordName) })
            self.cursor = nextCursor
        } catch {
            // Keep what we have; the footer button lets the user retry.
        }
    }

    func accountStatus() async -> CatalogAccountStatus {
        await provider.accountStatus()
    }

    /// Validate + normalize + create a SubmittedQuestion record. Throws
    /// `CatalogProviderError.validation` with all structural problems.
    func submit(prompt: String, typeRaw: Int, choices: [String], creditName: String?) async throws {
        let errors = CatalogValidation.validate(
            prompt: prompt, typeRaw: typeRaw, choices: choices, creditName: creditName
        )
        guard errors.isEmpty else { throw CatalogProviderError.validation(errors) }
        let normalized = CatalogValidation.normalized(
            prompt: prompt, choices: choices, creditName: creditName
        )
        try await provider.submit(
            prompt: normalized.prompt, typeRaw: typeRaw,
            choices: normalized.choices, creditName: normalized.creditName
        )
    }

    func flag(catalogRecordName: String, reason: String) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try await provider.flag(
            catalogRecordName: catalogRecordName,
            reason: trimmed.isEmpty ? "No reason given" : trimmed
        )
    }

    /// "Add to my questions": creates an ordinary LOCAL Question with a
    /// FRESH UUID (Question() generates one) — catalog identity never
    /// collides with sync identity, and no local schema changes are needed.
    /// Returns the created question, or nil when an identical prompt+type
    /// already exists (adding twice is a no-op, not a duplicate).
    @discardableResult
    func addToMyQuestions(_ entry: CatalogQuestion, context: ModelContext) -> Question? {
        guard let type = entry.type else { return nil }
        let existing = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        if existing.contains(where: { $0.prompt == entry.prompt && $0.typeRaw == entry.typeRaw }) {
            return nil
        }
        let question = QuestionAdmin.makeQuestion(
            prompt: entry.prompt, type: type, choices: entry.choices,
            placeholder: nil, kinds: [.regular], after: existing
        )
        context.insert(question)
        try? context.save()
        return question
    }
}
