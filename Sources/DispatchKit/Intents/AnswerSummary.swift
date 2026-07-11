import Foundation

/// Read-side helper for the App Intents query layer (plan 49): flatten a
/// `Response` to a display string and find the most recent answer to a
/// question across a set of reports. Report-centric — answers are always read
/// out of the `Report` they live in; there is no free-floating answer.
///
/// The per-type flattening mirrors the exporter precedence
/// (`MarkdownExporter.flattenedAnswer` / `CSVExporter.flatten`): those keep
/// their own private copies (pinned by their own determinism tests and out of
/// scope to refactor here); this is the intent-facing surface.
public enum AnswerSummary {
    /// One human-readable line for a response, or nil when the response
    /// carries no answer (skipped / payload-less, matching v1 export
    /// semantics). Empty collections are treated as no answer.
    public static func text(for response: Response) -> String? {
        if let tokens = response.tokens, !tokens.isEmpty {
            return tokens.map(\.text).joined(separator: ", ")
        }
        if let options = response.answeredOptions, !options.isEmpty {
            return options.joined(separator: ", ")
        }
        if let location = response.locationResponse {
            guard let text = location.text, !text.isEmpty else { return nil }
            return text
        }
        if let time = response.timeResponse {
            return time.dayOffset == -1 ? "\(time.hhmm) (yesterday)" : time.hhmm
        }
        if let numeric = response.numericResponse, !numeric.isEmpty {
            return numeric
        }
        if let texts = response.textResponses, !texts.isEmpty {
            return texts.map(\.text).joined(separator: "\n\n")
        }
        return nil
    }

    /// The most recent non-draft report's answered response for `id`, as
    /// display text plus that report's date. Drafts, payload-less responses,
    /// and other questions are skipped; ties break toward the later date.
    public static func lastAnswer(toQuestionID id: String,
                                  in reports: [Report]) -> (text: String, date: Date)? {
        reports
            .filter { !$0.isDraft }
            .sorted { $0.date > $1.date }
            .lazy
            .compactMap { report -> (text: String, date: Date)? in
                for response in report.responses ?? [] where response.questionIdentifier == id {
                    if let text = text(for: response) {
                        return (text: text, date: report.date)
                    }
                }
                return nil
            }
            .first
    }
}
