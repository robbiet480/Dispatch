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
    case inputStyleNotAllowed
    case defaultAnswerNotAllowed
    case defaultAnswerTooLong(limit: Int)
    case placeholderTooLong(limit: Int)

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
        case .inputStyleNotAllowed:
            "Input style only applies to number questions."
        case .defaultAnswerNotAllowed:
            "Default answers only apply to number questions."
        case .defaultAnswerTooLong(let limit):
            "Default answer must be \(limit) characters or fewer."
        case .placeholderTooLong(let limit):
            "Placeholder must be \(limit) characters or fewer."
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
    public static let defaultAnswerMaxLength = 40
    public static let placeholderMaxLength = 100

    /// Validate the structural shape of a question headed for (or from) the
    /// catalog. Returns every violation, not just the first, so forms can
    /// show all problems at once. Whitespace is trimmed before length checks;
    /// callers should persist the trimmed values (`normalized` below).
    public static func validate(
        prompt: String, typeRaw: Int, choices: [String], creditName: String? = nil,
        inputStyle: String? = nil, defaultAnswer: String? = nil, placeholder: String? = nil
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

        // Input configuration (plan 41). Structural gates only: style and
        // default answer are number-only (matching the editor, which writes
        // them exclusively for number questions); placeholder is allowed on
        // any type. An UNKNOWN style raw is never an error — it resolves to
        // the plain text field, the same leniency as `Question.inputStyle`.
        let trimmedStyle = inputStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedStyle.isEmpty, type != .number {
            errors.append(.inputStyleNotAllowed)
        }
        let trimmedDefault = defaultAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDefault.isEmpty {
            if type != .number {
                errors.append(.defaultAnswerNotAllowed)
            } else if trimmedDefault.count > defaultAnswerMaxLength {
                errors.append(.defaultAnswerTooLong(limit: defaultAnswerMaxLength))
            }
        }
        let trimmedPlaceholder = placeholder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPlaceholder.count > placeholderMaxLength {
            errors.append(.placeholderTooLong(limit: placeholderMaxLength))
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
    /// credit collapses to nil (anonymous by default), and the plan-41 input
    /// configuration strings follow the same "empty ⇒ nil" rule (nothing to
    /// carry). The numeric input bounds aren't strings and pass around this
    /// function untouched.
    public static func normalized(
        prompt: String, choices: [String], creditName: String?,
        inputStyle: String? = nil, defaultAnswer: String? = nil, placeholder: String? = nil
    ) -> (prompt: String, choices: [String], creditName: String?,
          inputStyle: String?, defaultAnswer: String?, placeholder: String?) {
        func collapse(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        return (
            prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            collapse(creditName),
            collapse(inputStyle),
            collapse(defaultAnswer),
            collapse(placeholder)
        )
    }
}
