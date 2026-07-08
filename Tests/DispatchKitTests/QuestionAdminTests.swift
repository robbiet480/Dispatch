import Foundation
import Testing
@testable import DispatchKit

private func q(_ id: String, sort: Int) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.sortOrder = sort
    return question
}

@Test func moveNormalizesContiguously() {
    var questions = [q("a", sort: 0), q("b", sort: 1), q("c", sort: 2)]
    QuestionAdmin.move(&questions, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(questions.map(\.uniqueIdentifier) == ["c", "a", "b"])
    #expect(questions.map(\.sortOrder) == [0, 1, 2])
}

@Test func makeQuestionAppendsAfterMax() {
    let existing = [q("a", sort: 0), q("b", sort: 7)]
    let made = QuestionAdmin.makeQuestion(prompt: "New?", type: .yesNo, choices: [],
                                          placeholder: nil, kinds: [.regular], after: existing)
    #expect(made.sortOrder == 8)
    #expect(made.prompt == "New?")
    #expect(made.type == .yesNo)
    #expect(made.reportKinds == [.regular])
}
