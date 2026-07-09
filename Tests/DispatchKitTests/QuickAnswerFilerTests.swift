import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// The shared quick-answer path (plan 17): one kit-side function used by
// BOTH the notification quick-answer actions (trigger .notification) and
// the interactive widget buttons (trigger .widget).

private func makeQuestion(
    prompt: String, type: QuestionType = .yesNo, sortOrder: Int = 0,
    isEnabled: Bool = true, kinds: [ReportKind] = [.regular],
    choices: [String] = []
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

@Test func firstEnabledYesNoQuestionSelectsBySortOrderAndEligibility() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let disabled = makeQuestion(prompt: "Disabled?", sortOrder: 0, isEnabled: false)
    let wakeOnly = makeQuestion(prompt: "Wake only?", sortOrder: 1, kinds: [.wake])
    let tokens = makeQuestion(prompt: "Tokens", type: .tokens, sortOrder: 2)
    let second = makeQuestion(prompt: "Second?", sortOrder: 4)
    let first = makeQuestion(prompt: "First?", sortOrder: 3)
    for question in [disabled, wakeOnly, tokens, second, first] {
        context.insert(question)
    }
    try context.save()

    let picked = QuickAnswerFiler.firstEnabledYesNoQuestion(in: context)
    #expect(picked?.prompt == "First?")
}

@Test func firstEnabledYesNoQuestionNilWhenNoneEligible() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(makeQuestion(prompt: "Tokens", type: .tokens))
    try context.save()
    #expect(QuickAnswerFiler.firstEnabledYesNoQuestion(in: context) == nil)
}

@Test func filesMinimalWidgetReportWithFallbackTitles() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let question = makeQuestion(prompt: "Are you working?")
    context.insert(question)
    try context.save()

    let date = Date(timeIntervalSince1970: 1_780_000_000)
    let report = try QuickAnswerFiler.file(
        question: question, choiceIndex: 0, trigger: .widget, date: date, in: context
    )

    #expect(report.kind == .regular)
    #expect(report.trigger == .widget)
    #expect(report.date == date)
    #expect(report.isBackdated == false)
    // Minimal report: no sensor payloads, exactly one response.
    #expect(report.battery == nil && report.location == nil && report.health.isEmpty)
    let responses = try #require(report.responses)
    #expect(responses.count == 1)
    #expect(responses.first?.questionIdentifier == question.uniqueIdentifier)
    #expect(responses.first?.answeredOptions == ["Yes"]) // no stored choices → fallback

    let noReport = try QuickAnswerFiler.file(
        question: question, choiceIndex: 1, trigger: .widget, in: context
    )
    #expect(noReport.responses?.first?.answeredOptions == ["No"])
}

@Test func filesCustomChoiceTitlesAndNotificationTrigger() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let question = makeQuestion(prompt: "Feeling good?", choices: ["Totally", "Nope"])
    context.insert(question)
    try context.save()

    let yes = try QuickAnswerFiler.file(
        question: question, choiceIndex: 0, trigger: .notification, in: context
    )
    #expect(yes.trigger == .notification)
    #expect(yes.responses?.first?.answeredOptions == ["Totally"])

    let no = try QuickAnswerFiler.file(
        question: question, choiceIndex: 1, trigger: .widget, in: context
    )
    #expect(no.responses?.first?.answeredOptions == ["Nope"])
}

// MARK: - QuickAnswerQuestion (widget display snapshot)

@Test func quickAnswerQuestionResolvesButtonTitlesWithFilingFallbacks() {
    let bare = makeQuestion(prompt: "Are you working?")
    let bareSnapshot = QuickAnswerQuestion(question: bare)
    #expect(bareSnapshot.questionID == bare.uniqueIdentifier)
    #expect(bareSnapshot.prompt == "Are you working?")
    #expect(bareSnapshot.yesTitle == "Yes")
    #expect(bareSnapshot.noTitle == "No")

    let custom = makeQuestion(prompt: "Feeling good?", choices: ["Totally", "Nope"])
    let customSnapshot = QuickAnswerQuestion(question: custom)
    #expect(customSnapshot.yesTitle == "Totally")
    #expect(customSnapshot.noTitle == "Nope")

    let oneChoice = makeQuestion(prompt: "Hydrated?", choices: ["Yep"])
    let oneSnapshot = QuickAnswerQuestion(question: oneChoice)
    #expect(oneSnapshot.yesTitle == "Yep")
    #expect(oneSnapshot.noTitle == "No")
}

// MARK: - WidgetQuickAnswerMarker (pending-action bridge)

private func freshDefaults() -> UserDefaults {
    let suite = "quick-answer-marker-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func markerRecordsAndDrainsOnce() {
    let defaults = freshDefaults()
    let filed = Date(timeIntervalSince1970: 1_780_000_000)

    #expect(WidgetQuickAnswerMarker.pendingActedAt(in: defaults) == nil)
    #expect(WidgetQuickAnswerMarker.takePendingActedAt(in: defaults) == nil)

    WidgetQuickAnswerMarker.recordFiled(at: filed, in: defaults)
    #expect(WidgetQuickAnswerMarker.pendingActedAt(in: defaults) == filed)
    #expect(WidgetQuickAnswerMarker.filedAt(in: defaults) == filed)

    // Drain is one-shot: the pending marker clears, filedAt (the transient
    // "Filed ✓" driver) survives for the widget to expire on its own.
    #expect(WidgetQuickAnswerMarker.takePendingActedAt(in: defaults) == filed)
    #expect(WidgetQuickAnswerMarker.pendingActedAt(in: defaults) == nil)
    #expect(WidgetQuickAnswerMarker.filedAt(in: defaults) == filed)
}

@Test func markerPendingNeverRegresses() {
    let defaults = freshDefaults()
    let newer = Date(timeIntervalSince1970: 1_780_000_000)
    let older = newer.addingTimeInterval(-600)

    WidgetQuickAnswerMarker.recordFiled(at: newer, in: defaults)
    WidgetQuickAnswerMarker.recordFiled(at: older, in: defaults)
    // Pending keeps the newer act; filedAt tracks the latest write.
    #expect(WidgetQuickAnswerMarker.pendingActedAt(in: defaults) == newer)
    #expect(WidgetQuickAnswerMarker.filedAt(in: defaults) == older)
}

@Test func markerFiledRecentlyWindowAndClockRollback() {
    let defaults = freshDefaults()
    let filed = Date(timeIntervalSince1970: 1_780_000_000)
    WidgetQuickAnswerMarker.recordFiled(at: filed, in: defaults)

    #expect(WidgetQuickAnswerMarker.filedRecently(in: defaults, now: filed))
    #expect(WidgetQuickAnswerMarker.filedRecently(
        in: defaults, now: filed.addingTimeInterval(WidgetQuickAnswerMarker.filedDisplayDuration - 1)))
    #expect(!WidgetQuickAnswerMarker.filedRecently(
        in: defaults, now: filed.addingTimeInterval(WidgetQuickAnswerMarker.filedDisplayDuration)))
    // Clock rolled back before the marker: not "recent".
    #expect(!WidgetQuickAnswerMarker.filedRecently(
        in: defaults, now: filed.addingTimeInterval(-1)))
    #expect(!WidgetQuickAnswerMarker.filedRecently(in: freshDefaults(), now: filed))
}

// MARK: - v2 export tolerance for the .widget trigger

@Test func v2RoundTripsWidgetTriggeredReport() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let question = makeQuestion(prompt: "Are you working?")
    context.insert(question)
    try context.save()
    try QuickAnswerFiler.file(question: question, choiceIndex: 0, trigger: .widget, in: context)

    let data = try V2Exporter.exportData(from: context)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"widget\""))

    let importContainer = try DispatchStore.inMemoryContainer()
    let importContext = ModelContext(importContainer)
    _ = try V2Importer.importExport(data, into: importContext)
    let reports = try importContext.fetch(FetchDescriptor<Report>())
    #expect(reports.count == 1)
    #expect(reports.first?.trigger == .widget)
}
