import Foundation

public enum QuestionAdmin {
    /// Rewrites sortOrder to 0..n-1 following the given array order.
    public static func normalizeOrder(_ questions: [Question]) {
        for (index, question) in questions.enumerated() {
            question.sortOrder = index
        }
    }

    public static func move(_ questions: inout [Question], fromOffsets: IndexSet, toOffset: Int) {
        // Extract the elements to move (in reverse order to maintain correct indices)
        let movedElements = fromOffsets
            .sorted(by: >)
            .map { questions.remove(at: $0) }
            .reversed()

        // Insert at the destination, adjusted for removals
        var insertIndex = toOffset
        for element in movedElements {
            questions.insert(element, at: insertIndex)
            insertIndex += 1
        }

        normalizeOrder(questions)
    }

    public static func makeQuestion(prompt: String, type: QuestionType, choices: [String],
                                    placeholder: String?, kinds: [ReportKind],
                                    after questions: [Question]) -> Question {
        let question = Question()
        question.prompt = prompt
        question.type = type
        question.choices = choices
        question.placeholderString = placeholder
        question.reportKinds = kinds
        question.sortOrder = (questions.map(\.sortOrder).max() ?? -1) + 1
        return question
    }
}
