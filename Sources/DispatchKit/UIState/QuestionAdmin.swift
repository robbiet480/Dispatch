import Foundation
import SwiftUI

public enum QuestionAdmin {
    /// Rewrites sortOrder to 0..n-1 following the given array order.
    public static func normalizeOrder(_ questions: [Question]) {
        for (index, question) in questions.enumerated() {
            question.sortOrder = index
        }
    }

    public static func move(_ questions: inout [Question], fromOffsets: IndexSet, toOffset: Int) {
        // MutableCollection.move(fromOffsets:toOffset:) uses pre-removal semantics
        // for toOffset, matching SwiftUI's List onMove contract exactly.
        questions.move(fromOffsets: fromOffsets, toOffset: toOffset)
        normalizeOrder(questions)
    }

    /// The input configuration params (plan 41) default to nil so existing
    /// callers compile unchanged. `inputStyle` is the raw `NumberInputStyle`
    /// string, stored untouched (an unknown raw resolves to the plain text
    /// field via `Question.inputStyle` — same leniency as sync/import).
    public static func makeQuestion(prompt: String, type: QuestionType, choices: [String],
                                    placeholder: String?, kinds: [ReportKind],
                                    after questions: [Question],
                                    defaultAnswer: String? = nil, inputStyle: String? = nil,
                                    inputMin: Double? = nil, inputMax: Double? = nil,
                                    inputStep: Double? = nil) -> Question {
        let question = Question()
        question.prompt = prompt
        question.type = type
        question.choices = choices
        question.placeholderString = placeholder
        question.reportKinds = kinds
        question.sortOrder = (questions.map(\.sortOrder).max() ?? -1) + 1
        question.defaultAnswerString = defaultAnswer
        question.inputStyleRaw = inputStyle
        question.inputMin = inputMin
        question.inputMax = inputMax
        question.inputStep = inputStep
        return question
    }
}
