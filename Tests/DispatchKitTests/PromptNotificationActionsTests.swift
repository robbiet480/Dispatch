import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// Reproduction + contract for the TestFlight bug: prompt notifications showed
// Yes/No quick-answer buttons even when the prompt was open-text (no eligible
// Yes/No question), and tapping them filed nothing — on the iPhone and,
// forwarded, on the Apple Watch. Yes/No must only be offered for a boolean
// question; an open-text prompt offers Snooze alone (tap opens the app).

private func makeQuestion(
    prompt: String, type: QuestionType, sortOrder: Int = 0,
    isEnabled: Bool = true, kinds: [ReportKind] = [.regular], choices: [String] = []
) -> Question {
    let question = Question()
    question.prompt = prompt
    question.type = type
    question.sortOrder = sortOrder
    question.isEnabled = isEnabled
    question.reportKinds = kinds
    question.choices = choices
    return question
}

@Test func openTextPromptOffersNoYesNoActions() {
    // The exact failure the tester hit: no eligible Yes/No question, so the
    // prompt body is the generic open-text fallback — yet Yes/No buttons
    // appeared and no-op'd. The category must offer ONLY snooze here.
    let identifiers = PromptNotificationActions.identifiers(hasYesNoQuestion: false)
    #expect(!identifiers.contains(NotificationIdentifiers.answerYesAction))
    #expect(!identifiers.contains(NotificationIdentifiers.answerNoAction))
    #expect(identifiers == [NotificationIdentifiers.snoozeAction])
}

@Test func booleanPromptOffersYesNoThenSnooze() {
    let identifiers = PromptNotificationActions.identifiers(hasYesNoQuestion: true)
    #expect(identifiers == [
        NotificationIdentifiers.answerYesAction,
        NotificationIdentifiers.answerNoAction,
        NotificationIdentifiers.snoozeAction,
    ])
}

@Test func storeWithoutYesNoQuestionOffersNoYesNoActions() throws {
    // Drive the decision straight from a question set with NO Yes/No question
    // (the open-text journaling configuration) — matches the reproduction of
    // the shipped inline logic that always attached Yes/No.
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(makeQuestion(prompt: "What are you up to right now?", type: .note))
    context.insert(makeQuestion(prompt: "Where are you?", type: .location, sortOrder: 1))
    try context.save()

    let identifiers = PromptNotificationActions.identifiers(in: context)
    #expect(!identifiers.contains(NotificationIdentifiers.answerYesAction))
    #expect(!identifiers.contains(NotificationIdentifiers.answerNoAction))
    #expect(identifiers == [NotificationIdentifiers.snoozeAction])
}

@Test func storeWithYesNoQuestionOffersYesNoActions() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(makeQuestion(prompt: "Note", type: .note))
    context.insert(makeQuestion(prompt: "Are you working?", type: .yesNo, sortOrder: 1))
    try context.save()

    let identifiers = PromptNotificationActions.identifiers(in: context)
    #expect(identifiers == [
        NotificationIdentifiers.answerYesAction,
        NotificationIdentifiers.answerNoAction,
        NotificationIdentifiers.snoozeAction,
    ])
}
