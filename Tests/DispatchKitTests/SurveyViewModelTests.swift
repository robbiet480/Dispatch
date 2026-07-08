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

@Test func selectClampsAndMoves() {
    let questions = [
        makeQuestion("q1", "Working?", .yesNo, sort: 0),
        makeQuestion("q2", "Doing?", .tokens, sort: 1),
    ]
    let viewModel = SurveyViewModel(questions: questions, kind: .regular)
    viewModel.select(1)
    #expect(viewModel.currentIndex == 1)
    viewModel.select(99) // clamps to last
    #expect(viewModel.currentIndex == 1)
    viewModel.select(-5) // clamps to first
    #expect(viewModel.currentIndex == 0)
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

@Test func emptyNumberAnswerFilesDefaultAnswerInsteadOfSkipped() {
    let withDefault = makeQuestion("q-num", "Coffees?", .number, sort: 0)
    withDefault.defaultAnswerString = "0"
    let withoutDefault = makeQuestion("q-num2", "Meetings?", .number, sort: 1)
    let viewModel = SurveyViewModel(questions: [withDefault, withoutDefault], kind: .regular)

    // Untouched: the default files for q-num, .skipped stays for q-num2.
    var drafts = viewModel.drafts()
    #expect(drafts[0].value == .number("0"))
    #expect(drafts[1].value == .skipped)

    // An explicit answer wins over the default.
    viewModel.answer(.number("3"), for: "q-num")
    drafts = viewModel.drafts()
    #expect(drafts[0].value == .number("3"))

    // Clearing back to skipped re-applies the default.
    viewModel.answer(.skipped, for: "q-num")
    #expect(viewModel.drafts()[0].value == .number("0"))
}

@Test func defaultAnswerOnlyAppliesToNumberQuestions() {
    // A non-number question with a stray defaultAnswerString must not file it.
    let note = makeQuestion("q-note", "Learn?", .note, sort: 0)
    note.defaultAnswerString = "nothing"
    let viewModel = SurveyViewModel(questions: [note], kind: .regular)
    #expect(viewModel.pages[0].defaultAnswer == nil)
    #expect(viewModel.drafts()[0].value == .skipped)
}

@Test func pagesCarryMultiSelectFlagWithBehaviorPreservingDefaults() {
    let multi = makeQuestion("q-mc", "Mood?", .multipleChoice, sort: 0, choices: ["A", "B"])
    let single = makeQuestion("q-mc1", "Pick one?", .multipleChoice, sort: 1, choices: ["A", "B"])
    single.allowsMultipleSelection = false
    let yesNo = makeQuestion("q-yn", "Working?", .yesNo, sort: 2)

    let viewModel = SurveyViewModel(questions: [multi, single, yesNo], kind: .regular)
    #expect(viewModel.pages[0].allowsMultipleSelection == true)
    #expect(viewModel.pages[1].allowsMultipleSelection == false)
    #expect(viewModel.pages[2].allowsMultipleSelection == false)
}
