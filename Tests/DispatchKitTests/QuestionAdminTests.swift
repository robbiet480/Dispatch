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

@Test func moveDownwardSingleElement() {
    var questions = [q("a", sort: 0), q("b", sort: 1), q("c", sort: 2)]
    QuestionAdmin.move(&questions, fromOffsets: IndexSet(integer: 0), toOffset: 2)
    #expect(questions.map(\.uniqueIdentifier) == ["b", "a", "c"])
    #expect(questions.map(\.sortOrder) == [0, 1, 2])
}

@Test func moveDownwardMultiElement() {
    var questions = [q("a", sort: 0), q("b", sort: 1), q("c", sort: 2), q("d", sort: 3)]
    QuestionAdmin.move(&questions, fromOffsets: IndexSet([0, 2]), toOffset: 4)
    #expect(questions.map(\.uniqueIdentifier) == ["b", "d", "a", "c"])
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

// MARK: - Input configuration (plan 41)

@Test func makeQuestionCarriesInputConfig() {
    let made = QuestionAdmin.makeQuestion(
        prompt: "Stress?", type: .number, choices: [],
        placeholder: "1–5", kinds: [.regular], after: [],
        defaultAnswer: "3", inputStyle: "scale",
        inputMin: 1, inputMax: 5, inputStep: 1
    )
    #expect(made.inputStyle == .scale)
    #expect(made.inputStyleRaw == "scale")
    #expect(made.inputMin == 1)
    #expect(made.inputMax == 5)
    #expect(made.inputStep == 1)
    #expect(made.defaultAnswerString == "3")
    #expect(made.placeholderString == "1–5")
}

@Test func makeQuestionDefaultsLeaveInputConfigNil() {
    // Existing call shape (no new args) produces a bare question — every
    // pre-plan-41 caller compiles and behaves unchanged.
    let made = QuestionAdmin.makeQuestion(prompt: "Bare?", type: .number, choices: [],
                                          placeholder: nil, kinds: [.regular], after: [])
    #expect(made.inputStyleRaw == nil)
    #expect(made.inputStyle == .textField)
    #expect(made.inputMin == nil)
    #expect(made.inputMax == nil)
    #expect(made.inputStep == nil)
    #expect(made.defaultAnswerString == nil)
    #expect(made.placeholderString == nil)
}

@Test func makeQuestionPreservesUnknownInputStyleRaw() {
    // Leniency: a future style raw persists untouched and resolves to the
    // plain text field on this build.
    let made = QuestionAdmin.makeQuestion(
        prompt: "Future?", type: .number, choices: [],
        placeholder: nil, kinds: [.regular], after: [],
        inputStyle: "hologram"
    )
    #expect(made.inputStyleRaw == "hologram")
    #expect(made.inputStyle == .textField)
}
