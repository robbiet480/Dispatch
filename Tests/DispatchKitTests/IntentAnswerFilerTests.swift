import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// IntentAnswerFiler (plan 43): the generalization of QuickAnswerFiler to any
// question type, backing the "Log Answer" Shortcuts action. Report-centric —
// every answer is filed INSIDE a real report via ReportBuilder.

// MARK: - coercion

@Test func coerceNumberKeepsRawString() {
    #expect(IntentAnswerFiler.coercedValue(forType: .number, choices: [], raw: "2") == .number("2"))
    #expect(IntentAnswerFiler.coercedValue(forType: .number, choices: [], raw: " 3.5 ") == .number("3.5"))
}

@Test func coerceYesNoMatchesChoicesThenAffirmativeWords() {
    let choices = ["Absolutely", "Nope"]
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: choices, raw: "absolutely") == .options(["Absolutely"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: choices, raw: "yes") == .options(["Absolutely"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: choices, raw: "no") == .options(["Nope"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: choices, raw: "1") == .options(["Absolutely"]))
    // No choices → literal fallback.
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: [], raw: "true") == .options(["Yes"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .yesNo, choices: [], raw: "off") == .options(["No"]))
}

@Test func coerceMultipleChoiceMatchesElseVerbatim() {
    let choices = ["Red", "Green", "Blue"]
    #expect(IntentAnswerFiler.coercedValue(forType: .multipleChoice, choices: choices, raw: "green") == .options(["Green"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .multipleChoice, choices: choices, raw: "Teal") == .options(["Teal"]))
}

@Test func coerceTokensAndPeopleSplitOnCommas() {
    #expect(IntentAnswerFiler.coercedValue(forType: .tokens, choices: [], raw: "walk, coffee ,  read") == .tokens(["walk", "coffee", "read"]))
    #expect(IntentAnswerFiler.coercedValue(forType: .people, choices: [], raw: "Alice,Bob") == .tokens(["Alice", "Bob"]))
}

@Test func coerceNoteAndLocationVerbatim() {
    #expect(IntentAnswerFiler.coercedValue(forType: .note, choices: [], raw: "a long day") == .note("a long day"))
    #expect(IntentAnswerFiler.coercedValue(forType: .location, choices: [], raw: "Office") == .location(text: "Office"))
}

@Test func coerceTimeParsesHHMMElseSkipped() {
    #expect(IntentAnswerFiler.coercedValue(forType: .time, choices: [], raw: "9:05") == .time(TimeAnswer(minutesSinceMidnight: 9 * 60 + 5)))
    #expect(IntentAnswerFiler.coercedValue(forType: .time, choices: [], raw: "22:30") == .time(TimeAnswer(minutesSinceMidnight: 22 * 60 + 30)))
    #expect(IntentAnswerFiler.coercedValue(forType: .time, choices: [], raw: "lunchtime") == .skipped)
}

@Test func coerceEmptyRawIsSkipped() {
    #expect(IntentAnswerFiler.coercedValue(forType: .number, choices: [], raw: "   ") == .skipped)
    #expect(IntentAnswerFiler.coercedValue(forType: .tokens, choices: [], raw: "") == .skipped)
}

// MARK: - eligibility + filing

private func makeQuestion(
    prompt: String, type: QuestionType = .number, isEnabled: Bool = true,
    kinds: [ReportKind] = [.regular], choices: [String] = []
) -> Question {
    let q = Question()
    q.prompt = prompt
    q.type = type
    q.isEnabled = isEnabled
    q.reportKinds = kinds
    q.choices = choices
    return q
}

@Test func eligibleQuestionRequiresEnabledRegular() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let ok = makeQuestion(prompt: "Coffees")
    let disabled = makeQuestion(prompt: "Disabled", isEnabled: false)
    let wakeOnly = makeQuestion(prompt: "Wake", kinds: [.wake])
    for q in [ok, disabled, wakeOnly] { context.insert(q) }
    try context.save()

    #expect(IntentAnswerFiler.eligibleQuestion(id: ok.uniqueIdentifier, in: context)?.prompt == "Coffees")
    #expect(IntentAnswerFiler.eligibleQuestion(id: disabled.uniqueIdentifier, in: context) == nil)
    #expect(IntentAnswerFiler.eligibleQuestion(id: wakeOnly.uniqueIdentifier, in: context) == nil)
    #expect(IntentAnswerFiler.eligibleQuestion(id: "nonexistent", in: context) == nil)
}

@Test func fileCreatesOneIntentReportWithCoercedAnswer() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let question = makeQuestion(prompt: "Coffees")
    context.insert(question)
    try context.save()

    let date = Date(timeIntervalSince1970: 1_780_000_000)
    let report = try IntentAnswerFiler.file(
        questionID: question.uniqueIdentifier, raw: "2", trigger: .intent, date: date, in: context
    )
    #expect(report != nil)
    #expect(report?.trigger == .intent)
    #expect(report?.kind == .regular)
    #expect(report?.date == date)
    #expect(report?.responses?.count == 1)
    let response = try #require(report?.responses?.first)
    #expect(response.questionIdentifier == question.uniqueIdentifier)
    #expect(response.numericResponse == "2")

    // Exactly one report exists in the store.
    #expect(try context.fetchCount(FetchDescriptor<Report>()) == 1)
}

@Test func fileReturnsNilForIneligibleQuestion() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let disabled = makeQuestion(prompt: "Disabled", isEnabled: false)
    context.insert(disabled)
    try context.save()

    #expect(try IntentAnswerFiler.file(questionID: disabled.uniqueIdentifier, raw: "x", trigger: .intent, date: Date(), in: context) == nil)
    #expect(try IntentAnswerFiler.file(questionID: "missing", raw: "x", trigger: .intent, date: Date(), in: context) == nil)
    #expect(try context.fetchCount(FetchDescriptor<Report>()) == 0)
}
