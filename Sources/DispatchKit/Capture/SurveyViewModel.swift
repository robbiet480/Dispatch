import Foundation
import Observation

public struct SurveyPage: Identifiable, Sendable {
    public let id: String
    public let question: QuestionRef
    public let choices: [String]
    public let placeholder: String?
    /// Whether a multiple-choice page allows more than one selected option.
    public let allowsMultipleSelection: Bool
    /// Number questions: value filed when the answer is left empty (nil = skip).
    public let defaultAnswer: String?
}

/// Drives the paged survey: question filtering/ordering, current page,
/// and per-question answer state. UI-framework-free for testability.
@Observable
public final class SurveyViewModel {
    public private(set) var pages: [SurveyPage]
    public private(set) var currentIndex = 0
    private var answers: [String: AnswerValue] = [:]

    public init(questions: [Question], kind: ReportKind) {
        pages = questions
            .filter { $0.isEnabled && $0.reportKinds.contains(kind) }
            .sorted {
                ($0.sortOrder, $0.uniqueIdentifier) < ($1.sortOrder, $1.uniqueIdentifier)
            }
            .map { question in
                var choices = question.choices
                if question.type == .yesNo && choices.isEmpty {
                    choices = ["Yes", "No"]
                }
                return SurveyPage(
                    id: question.uniqueIdentifier,
                    question: QuestionRef(uniqueIdentifier: question.uniqueIdentifier,
                                          prompt: question.prompt,
                                          type: question.type),
                    choices: choices,
                    placeholder: question.placeholderString,
                    allowsMultipleSelection: question.allowsMultipleSelection,
                    defaultAnswer: question.type == .number ? question.defaultAnswerString : nil)
            }
    }

    public var isLastPage: Bool { currentIndex >= pages.count - 1 }

    public func advance() {
        currentIndex = min(currentIndex + 1, max(pages.count - 1, 0))
    }

    public func goBack() {
        currentIndex = max(currentIndex - 1, 0)
    }

    /// Jumps to `index`, clamped to a valid page. Used by the TabView swipe
    /// binding so gestures stay in sync with the footer and page counter.
    public func select(_ index: Int) {
        currentIndex = min(max(index, 0), max(pages.count - 1, 0))
    }

    public func answer(_ value: AnswerValue, for id: String) {
        answers[id] = value
    }

    public func answerValue(for id: String) -> AnswerValue {
        answers[id] ?? .skipped
    }

    public func drafts() -> [AnswerDraft] {
        pages.map { page in
            var value = answerValue(for: page.id)
            // Number questions with a default answer file that value instead of
            // `.skipped` when the user left the field empty.
            if case .skipped = value, let defaultAnswer = page.defaultAnswer, !defaultAnswer.isEmpty {
                value = .number(defaultAnswer)
            }
            return AnswerDraft(question: page.question, value: value)
        }
    }
}
