import Foundation
import Observation

public struct SurveyPage: Identifiable, Sendable {
    public let id: String
    public let question: QuestionRef
    public let choices: [String]
    public let placeholder: String?
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
                    placeholder: question.placeholderString)
            }
    }

    public var isLastPage: Bool { currentIndex >= pages.count - 1 }

    public func advance() {
        currentIndex = min(currentIndex + 1, max(pages.count - 1, 0))
    }

    public func goBack() {
        currentIndex = max(currentIndex - 1, 0)
    }

    public func answer(_ value: AnswerValue, for id: String) {
        answers[id] = value
    }

    public func answerValue(for id: String) -> AnswerValue {
        answers[id] ?? .skipped
    }

    public func drafts() -> [AnswerDraft] {
        pages.map { AnswerDraft(question: $0.question, value: answerValue(for: $0.id)) }
    }
}
