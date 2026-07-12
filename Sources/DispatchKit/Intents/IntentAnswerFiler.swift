import Foundation
import SwiftData

/// The write-side backing for the "Log Answer" App Intent (plan 49): the
/// generalization of `QuickAnswerFiler` from a single Yes/No question to any
/// question type. Report-centric — the answer is filed INSIDE a real,
/// minimal `Report` through the shared `ReportBuilder` path; there is no
/// free-floating answer. Sensor capture is out of budget for an out-of-process
/// intent (the `QuickAnswerFiler` constraint), so intent-filed reports carry
/// provenance but no live sensors.
///
/// Pure/`ModelContext` only — no `AppIntents` import — so the coercion and
/// filing are unit-testable without an intent process.
public enum IntentAnswerFiler {
    /// Thrown by `file` when the raw value carries no recordable answer — it
    /// coerced to `.skipped` (whitespace-only input, an empty token list, or
    /// an unparseable time). Distinct from a `nil` return (question
    /// missing/ineligible) so the intent can tell "no such question" apart
    /// from "nothing to record", and neither path files a phantom
    /// payload-less report.
    public enum FilingError: Error, Equatable {
        case unrecordableValue
    }

    /// Words a Yes/No answer treats as affirmative when the raw value doesn't
    /// match a stored choice (case-insensitive, trimmed).
    private static let affirmativeWords: Set<String> = ["yes", "y", "true", "1", "on", "yep", "yeah"]

    /// Maps a raw Shortcuts string to the `AnswerValue` for a question's type.
    /// Lenient and type-directed (see plan 49 design decisions). An empty
    /// (whitespace-only) raw value is always `.skipped`.
    public static func coercedValue(forType type: QuestionType,
                                    choices: [String], raw: String) -> AnswerValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipped }

        switch type {
        case .number:
            return .number(trimmed)

        case .yesNo:
            if let match = choices.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return .options([match])
            }
            let affirmative = affirmativeWords.contains(trimmed.lowercased())
            if choices.count >= 2 {
                return .options([affirmative ? choices[0] : choices[1]])
            }
            if choices.count == 1 {
                // Only an affirmative label stored; fall back to a literal
                // "No" for the negative case.
                return .options([affirmative ? choices[0] : "No"])
            }
            return .options([affirmative ? "Yes" : "No"])

        case .multipleChoice:
            if let match = choices.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return .options([match])
            }
            return .options([trimmed])

        case .tokens, .people:
            let parts = trimmed.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? .skipped : .tokens(parts)

        case .note:
            return .note(trimmed)

        case .location:
            return .location(text: trimmed)

        case .time:
            guard let time = parseTime(trimmed) else { return .skipped }
            return .time(time)
        }
    }

    /// The question a Log-Answer intent may target: enabled and part of the
    /// regular report surface (the manual-entry kind). Mirrors the
    /// `QuickAnswerFiler` eligibility spirit, minus the Yes/No restriction.
    public static func eligibleQuestion(id: String, in context: ModelContext) -> Question? {
        var descriptor = FetchDescriptor<Question>(
            predicate: #Predicate { $0.uniqueIdentifier == id }
        )
        descriptor.fetchLimit = 1
        guard let question = try? context.fetch(descriptor).first,
              question.isEnabled,
              question.reportKinds.contains(.regular) else { return nil }
        return question
    }

    /// Files a minimal report containing the single coerced answer for the
    /// question identified by `questionID`. Returns nil (nothing saved) when
    /// the question is missing or ineligible; throws
    /// `FilingError.unrecordableValue` when the raw value coerces to
    /// `.skipped` (whitespace-only, an empty token list, an unparseable
    /// time) — filing that would create a phantom payload-less report and a
    /// blank confirmation, so it's rejected before touching the store.
    @discardableResult
    public static func file(questionID: String, raw: String, trigger: ReportTrigger,
                            date: Date = Date(), in context: ModelContext) throws -> Report? {
        guard let question = eligibleQuestion(id: questionID, in: context) else { return nil }
        let ref = QuestionRef(
            uniqueIdentifier: question.uniqueIdentifier,
            prompt: question.prompt,
            type: question.type
        )
        let value = coercedValue(forType: question.type, choices: question.choices, raw: raw)
        guard value != .skipped else { throw FilingError.unrecordableValue }
        return try ReportBuilder.save(
            kind: .regular,
            trigger: trigger,
            date: date,
            timeZone: .current,
            outcomes: [:],
            answers: [AnswerDraft(question: ref, value: value)],
            in: context
        )
    }

    /// Parses a 24-hour `H:mm` / `HH:mm` wall-clock string to a `TimeAnswer`;
    /// nil for anything else (locale-independent, no `DateFormatter`).
    private static func parseTime(_ raw: String) -> TimeAnswer? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return TimeAnswer(minutesSinceMidnight: hour * 60 + minute)
    }
}
