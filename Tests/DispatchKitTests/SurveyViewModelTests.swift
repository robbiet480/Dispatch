import Foundation
import Testing
@testable import DispatchKit

private func makeQuestion(_ id: String, _ prompt: String, _ type: QuestionType,
                          sort: Int, enabled: Bool = true,
                          kinds: [ReportKind] = [.regular], choices: [String] = []) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.sortOrder = sort
    question.isEnabled = enabled
    question.reportKinds = kinds
    question.choices = choices
    return question
}

@Test func filtersAndOrdersQuestions() {
    let questions = [
        makeQuestion("q3", "Third?", .note, sort: 3),
        makeQuestion("q1", "First?", .yesNo, sort: 1),
        makeQuestion("q-off", "Disabled?", .yesNo, sort: 0, enabled: false),
        makeQuestion("q-wake", "How did you sleep?", .multipleChoice, sort: 2, kinds: [.wake]),
        makeQuestion("q2", "Second?", .tokens, sort: 2),
    ]
    let viewModel = SurveyViewModel(questions: questions, kind: .regular)
    #expect(viewModel.pages.map(\.id) == ["q1", "q2", "q3"])

    let wakeViewModel = SurveyViewModel(questions: questions, kind: .wake)
    #expect(wakeViewModel.pages.map(\.id) == ["q-wake"])
}

@Test func yesNoGetsImplicitChoices() {
    let viewModel = SurveyViewModel(questions: [makeQuestion("q1", "Working?", .yesNo, sort: 0)], kind: .regular)
    #expect(viewModel.pages[0].choices == ["Yes", "No"])
}

@Test func navigationAndAnswers() {
    let questions = [
        makeQuestion("q1", "Working?", .yesNo, sort: 0),
        makeQuestion("q2", "Doing?", .tokens, sort: 1),
    ]
    let viewModel = SurveyViewModel(questions: questions, kind: .regular)
    #expect(viewModel.currentIndex == 0)
    #expect(!viewModel.isLastPage)
    viewModel.answer(.options(["Yes"]), for: "q1")
    viewModel.advance()
    #expect(viewModel.isLastPage)
    viewModel.advance() // clamps
    #expect(viewModel.currentIndex == 1)
    viewModel.goBack()
    #expect(viewModel.currentIndex == 0)
    #expect(viewModel.answerValue(for: "q1") == .options(["Yes"]))

    let drafts = viewModel.drafts()
    #expect(drafts.count == 2)
    #expect(drafts[0].value == .options(["Yes"]))
    #expect(drafts[1].value == .skipped)
    #expect(drafts[1].question.uniqueIdentifier == "q2")
}
