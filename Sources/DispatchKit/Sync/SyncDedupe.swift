import Foundation
import SwiftData

/// Counts of duplicate rows removed by a `SyncDedupe.run` pass, per type.
public struct DedupeSummary: Equatable, Sendable {
    public var questionsRemoved = 0
    public var promptGroupsRemoved = 0
    public var tokensRemoved = 0
    public var peopleRemoved = 0
    public var reportsRemoved = 0

    public var totalRemoved: Int {
        questionsRemoved + promptGroupsRemoved + tokensRemoved + peopleRemoved + reportsRemoved
    }

    public init() {}
}

/// Merges the duplicates that CloudKit sync (or importing the same export on
/// two devices) can materialize: rows that share a `uniqueIdentifier`
/// (Question / PromptGroup / Report) or `text` (TokenEntity / PersonEntity).
///
/// Survivor choice is deterministic — the candidate with the lowest encoded
/// persistent identifier — so repeated passes over the same store always
/// converge on the same row. Nothing is rewritten on merge beyond vocabulary
/// usage counts: cross-references are by uniqueIdentifier string (group
/// membership, Response rows reference question prompts/IDs), so deleting the
/// extra rows is sufficient. CloudKit's last-writer-wins already reconciled
/// field values. Reports sharing a uniqueIdentifier are exact duplicates;
/// extras are deleted (cascade removes their responses).
public enum SyncDedupe {
    /// Runs the full dedupe pass. Saves once, and only when something was
    /// actually removed. Returns per-type removal counts.
    public static func run(in context: ModelContext) throws -> DedupeSummary {
        var summary = DedupeSummary()
        summary.questionsRemoved = try deleteDuplicates(Question.self, in: context) { $0.uniqueIdentifier }
        summary.promptGroupsRemoved = try deleteDuplicates(PromptGroup.self, in: context) { $0.uniqueIdentifier }
        summary.reportsRemoved = try deleteDuplicates(Report.self, in: context) { $0.uniqueIdentifier }
        summary.tokensRemoved = try mergeVocabulary(TokenEntity.self, in: context)
        summary.peopleRemoved = try mergeVocabulary(PersonEntity.self, in: context)
        if summary.totalRemoved > 0 {
            try context.save()
        }
        return summary
    }

    // MARK: - Duplicate resolution

    /// Groups all rows of `type` by `key` and deletes everything but the
    /// deterministic survivor in each group. Returns the number deleted.
    private static func deleteDuplicates<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext, key: (T) -> String
    ) throws -> Int {
        var removed = 0
        for group in try duplicateGroups(type, in: context, key: key) {
            for extra in group.dropFirst() {
                context.delete(extra)
                removed += 1
            }
        }
        return removed
    }

    /// Vocabulary merge: same survivor rule, but usage counts from the
    /// deleted extras are summed into the survivor and the survivor's
    /// questionCount keeps the maximum seen (per-question membership can't be
    /// reconstructed from counts alone; the next VocabularyBuilder.rebuild
    /// recomputes both exactly).
    private static func mergeVocabulary<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> Int where T: VocabularyCountable {
        var removed = 0
        for group in try duplicateGroups(type, in: context, key: { $0.vocabularyText }) {
            guard let survivor = group.first else { continue }
            for extra in group.dropFirst() {
                survivor.usageCount += extra.usageCount
                survivor.questionCount = max(survivor.questionCount, extra.questionCount)
                context.delete(extra)
                removed += 1
            }
        }
        return removed
    }

    /// All groups of 2+ rows sharing a key, each sorted survivor-first.
    private static func duplicateGroups<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext, key: (T) -> String
    ) throws -> [[T]] {
        let all = try context.fetch(FetchDescriptor<T>())
        let grouped = Dictionary(grouping: all, by: key)
        return grouped.values
            .filter { $0.count > 1 }
            .map { $0.sorted { persistentIDString($0) < persistentIDString($1) } }
    }

    /// Stable, deterministic ordering key for survivor choice. The encoded
    /// PersistentIdentifier is stable for a given row in a given store, so
    /// repeated passes always pick the same survivor. (Internal, not private,
    /// so tests can assert the survivor matches the rule.)
    static func persistentIDString(_ model: some PersistentModel) -> String {
        // .sortedKeys is load-bearing: JSONEncoder's default key order varies
        // call-to-call, which would make the sort (and thus the survivor)
        // unstable within a single pass.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(model.persistentModelID),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: model.persistentModelID)
    }
}

/// The shared shape of TokenEntity/PersonEntity that dedupe merges over.
protocol VocabularyCountable: AnyObject {
    var vocabularyText: String { get }
    var usageCount: Int { get set }
    var questionCount: Int { get set }
}

extension TokenEntity: VocabularyCountable {
    var vocabularyText: String { text }
}

extension PersonEntity: VocabularyCountable {
    var vocabularyText: String { text }
}
