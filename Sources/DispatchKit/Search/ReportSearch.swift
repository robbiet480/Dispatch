import Foundation

public enum ReportSearch {
    /// Returns true if the report matches the query (case and diacritic insensitive substring match).
    /// Empty or whitespace-only query matches everything.
    /// Searches over: note text (textResponses), token texts, people tokens (all token payloads),
    /// location answer text, placemark locality and name.
    public static func matches(_ report: Report, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }

        let normalizedQuery = normalize(trimmed)

        // Search note text (textResponses)
        for response in report.responses ?? [] {
            if let textResponses = response.textResponses {
                for token in textResponses {
                    if normalize(token.text).contains(normalizedQuery) {
                        return true
                    }
                }
            }
            // Search token texts (including people tokens)
            if let tokens = response.tokens {
                for token in tokens {
                    if normalize(token.text).contains(normalizedQuery) {
                        return true
                    }
                }
            }
            // Search location answer text
            if let locationResponse = response.locationResponse,
               let text = locationResponse.text {
                if normalize(text).contains(normalizedQuery) {
                    return true
                }
            }
        }

        // Search placemark locality and name
        if let location = report.location {
            if let placemark = location.placemark {
                if let locality = placemark.locality,
                   normalize(locality).contains(normalizedQuery) {
                    return true
                }
                if let name = placemark.name,
                   normalize(name).contains(normalizedQuery) {
                    return true
                }
            }
        }

        return false
    }

    /// Filters an array of reports to include only those matching the query.
    public static func filter(_ reports: [Report], query: String) -> [Report] {
        reports.filter { matches($0, query: query) }
    }

    /// Normalizes a string for case and diacritic insensitive comparison.
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
