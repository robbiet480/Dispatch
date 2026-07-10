import Foundation

/// Structural validation shared by the app's submit form and `dispatch-mod`'s
/// approve path. Deliberately structural ONLY: profanity/URL/content rejection
/// is not attempted client-side — that is exactly what human moderation is
/// for. Pure functions, no I/O.
public enum CatalogValidationError: Error, Equatable, Sendable {
    case emptyPrompt
    case promptTooLong(limit: Int)
    case unknownQuestionType(raw: Int)
    case tooFewChoices(minimum: Int)
    case tooManyChoices(limit: Int)
    case emptyChoice
    case choiceTooLong(limit: Int)
    case duplicateChoice(String)
    case choicesNotAllowed
    case creditNameTooLong(limit: Int)
    case flagReasonTooLong(limit: Int)

    /// Human-readable description for form errors and mod-tool output.
    public var message: String {
        switch self {
        case .emptyPrompt:
            "Prompt is empty."
        case .promptTooLong(let limit):
            "Prompt is longer than \(limit) characters."
        case .unknownQuestionType(let raw):
            "Unknown question type (\(raw))."
        case .tooFewChoices(let minimum):
            "Multiple-choice questions need at least \(minimum) choices."
        case .tooManyChoices(let limit):
            "Multiple-choice questions allow at most \(limit) choices."
        case .emptyChoice:
            "Choices can't be empty."
        case .choiceTooLong(let limit):
            "Each choice must be \(limit) characters or fewer."
        case .duplicateChoice(let choice):
            "Duplicate choice: \(choice)."
        case .choicesNotAllowed:
            "Only multiple-choice questions carry choices."
        case .creditNameTooLong(let limit):
            "Credit name must be \(limit) characters or fewer."
        case .flagReasonTooLong(let limit):
            "Flag reason must be \(limit) characters or fewer."
        }
    }
}

public enum CatalogValidation {
    public static let promptMaxLength = 200
    public static let choiceMaxLength = 60
    public static let choicesMinimumCount = 2
    public static let choicesMaxCount = 20
    public static let creditNameMaxLength = 50
    public static let flagReasonMaxLength = 500

    /// Validate the structural shape of a question headed for (or from) the
    /// catalog. Returns every violation, not just the first, so forms can
    /// show all problems at once. Whitespace is trimmed before length checks;
    /// callers should persist the trimmed values (`normalized` below).
    public static func validate(
        prompt: String, typeRaw: Int, choices: [String], creditName: String? = nil
    ) -> [CatalogValidationError] {
        var errors: [CatalogValidationError] = []

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            errors.append(.emptyPrompt)
        } else if trimmedPrompt.count > promptMaxLength {
            errors.append(.promptTooLong(limit: promptMaxLength))
        }

        guard let type = QuestionType(rawValue: typeRaw) else {
            errors.append(.unknownQuestionType(raw: typeRaw))
            return errors
        }

        let trimmedChoices = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if type == .multipleChoice {
            if trimmedChoices.count < choicesMinimumCount {
                errors.append(.tooFewChoices(minimum: choicesMinimumCount))
            }
            if trimmedChoices.count > choicesMaxCount {
                errors.append(.tooManyChoices(limit: choicesMaxCount))
            }
            if trimmedChoices.contains(where: \.isEmpty) {
                errors.append(.emptyChoice)
            }
            if trimmedChoices.contains(where: { $0.count > choiceMaxLength }) {
                errors.append(.choiceTooLong(limit: choiceMaxLength))
            }
            var seen = Set<String>()
            for choice in trimmedChoices where !choice.isEmpty {
                if !seen.insert(choice.lowercased()).inserted {
                    errors.append(.duplicateChoice(choice))
                    break
                }
            }
        } else if trimmedChoices.contains(where: { !$0.isEmpty }) {
            errors.append(.choicesNotAllowed)
        }

        if let creditName {
            let trimmedCredit = creditName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCredit.count > creditNameMaxLength {
                errors.append(.creditNameTooLong(limit: creditNameMaxLength))
            }
        }

        return errors
    }

    /// Validate a flag reason: trimmed, bounded at `flagReasonMaxLength`
    /// characters — symmetric with the prompt/choice/credit bounds above.
    /// Empty reasons are allowed (the write site substitutes a default).
    public static func validateFlagReason(_ reason: String) -> [CatalogValidationError] {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > flagReasonMaxLength
            ? [.flagReasonTooLong(limit: flagReasonMaxLength)]
            : []
    }

    /// Trimmed, persistence-ready copies of the user-entered values. Empty
    /// credit collapses to nil (anonymous by default).
    public static func normalized(
        prompt: String, choices: [String], creditName: String?
    ) -> (prompt: String, choices: [String], creditName: String?) {
        let trimmedCredit = creditName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            (trimmedCredit?.isEmpty ?? true) ? nil : trimmedCredit
        )
    }
}
