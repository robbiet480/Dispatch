import Foundation

/// Pure ranking logic for token/people autocomplete suggestions drawn from
/// previously used vocabulary (`TokenEntity` / `PersonEntity`).
///
/// Ranking: case- and diacritic-insensitive prefix matches first, then
/// substring matches; within each group, higher `usageCount` first, ties
/// broken by localized-lowercase alphabetical order. An empty or
/// whitespace-only query returns the top candidates by usage so a freshly
/// focused field can surface the most-used entries.
public enum TokenSuggester {
    public static func suggest(query: String,
                               candidates: [(text: String, usageCount: Int)],
                               excluding: [String],
                               limit: Int = 8) -> [String] {
        let excluded = Set(excluding.map(normalize))
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))

        let eligible = candidates.filter { !excluded.contains(normalize($0.text)) }

        func rankKey(_ candidate: (text: String, usageCount: Int)) -> (Int, String) {
            (-candidate.usageCount, candidate.text.lowercased(with: .current))
        }

        if normalizedQuery.isEmpty {
            return Array(eligible.sorted { rankKey($0) < rankKey($1) }
                .prefix(limit)
                .map(\.text))
        }

        var prefixMatches: [(text: String, usageCount: Int)] = []
        var substringMatches: [(text: String, usageCount: Int)] = []
        for candidate in eligible {
            let normalized = normalize(candidate.text)
            if normalized.hasPrefix(normalizedQuery) {
                prefixMatches.append(candidate)
            } else if normalized.contains(normalizedQuery) {
                substringMatches.append(candidate)
            }
        }

        let ranked = prefixMatches.sorted { rankKey($0) < rankKey($1) }
            + substringMatches.sorted { rankKey($0) < rankKey($1) }
        return Array(ranked.prefix(limit).map(\.text))
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
