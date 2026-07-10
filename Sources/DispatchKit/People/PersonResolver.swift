import Foundation
import SwiftData

/// The person-identity resolution layer (plan 22). Report answers stay name
/// text; consumers resolve text → `PersonEntity` through this type so renames
/// and merges heal everywhere without rewriting history.
public enum PersonResolver {
    /// The first person whose display name or any alternate name matches
    /// `text` case- and diacritic-insensitively. Candidates are scanned in
    /// the order given; pass a deterministically sorted array when the pick
    /// must be stable across runs.
    public static func person(matching text: String, in people: [PersonEntity]) -> PersonEntity? {
        let target = normalize(text)
        guard !target.isEmpty else { return nil }
        return people.first { person in
            normalize(person.text) == target
                || person.alternateNames.contains { normalize($0) == target }
        }
    }

    /// Renames a person: the old display name moves into `alternateNames`
    /// (deduped case/diacritic-insensitively, never duplicating the new
    /// display name), and `text` becomes `newName`. Historical reports keep
    /// their original text but resolve to the same person.
    public static func rename(_ person: PersonEntity, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldName = person.text
        var alternates = person.alternateNames
        if !oldName.isEmpty {
            alternates.append(oldName)
        }
        person.text = trimmed
        person.alternateNames = dedupe(alternates, excludingNameOf: person)
    }

    /// Merges `absorbed` into `survivor`: the survivor absorbs the absorbed
    /// person's display name and alternates into its own alternates, usage
    /// counts are summed, and the absorbed row is deleted. Saves the context.
    public static func merge(_ absorbed: PersonEntity, into survivor: PersonEntity,
                             context: ModelContext) throws {
        guard absorbed !== survivor else { return }
        var alternates = survivor.alternateNames
        if !absorbed.text.isEmpty {
            alternates.append(absorbed.text)
        }
        alternates.append(contentsOf: absorbed.alternateNames)
        survivor.alternateNames = dedupe(alternates, excludingNameOf: survivor)
        survivor.usageCount += absorbed.usageCount
        // usageCount sums (per-occurrence, additive across the two people),
        // but questionCount keeps the MAX: per-question membership can't be
        // reconstructed from counts alone — summing would double-count
        // questions both people appeared under. Mirrors SyncDedupe's
        // vocabulary merge; the next VocabularyBuilder.rebuild recomputes
        // both exactly.
        survivor.questionCount = max(survivor.questionCount, absorbed.questionCount)
        context.delete(absorbed)
        try context.save()
    }

    /// Case/diacritic folding shared by all person-name comparisons.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Order-preserving dedupe (case/diacritic-insensitive), dropping empties
    /// and anything that collides with the person's current display name.
    private static func dedupe(_ names: [String], excludingNameOf person: PersonEntity) -> [String] {
        var seen: Set<String> = [normalize(person.text)]
        var result: [String] = []
        for name in names {
            let key = normalize(name)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }
}
