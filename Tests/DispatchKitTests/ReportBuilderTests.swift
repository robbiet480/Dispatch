import Foundation
import SwiftData
import Testing
@testable import DispatchKit

private func ref(_ id: String, _ prompt: String, _ type: QuestionType) -> QuestionRef {
    QuestionRef(uniqueIdentifier: id, prompt: prompt, type: type)
}

@Test func savesReportWithSensorsAndAnswers() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let outcomes: [SensorKind: SensorOutcome] = [
        .battery: .captured(.battery(0.42)),
        .audio: .captured(.audio(AudioSample(avg: -50, peak: -30))),
        .altitude: .captured(.altitude(63.0)),
        .connection: .captured(.connection(1)),
        .focus: .captured(.focus(FocusState(label: nil, isFocused: true))),
        .healthSteps: .captured(.health([HealthReading(type: "steps", value: 1200, unit: "count")])),
        .healthHeart: .captured(.health([HealthReading(type: "heartRateAvg", value: 68, unit: "bpm")])),
        .weather: .unavailable(reason: "timed out"),
        .photos: .disabled,
    ]
    let answers: [AnswerDraft] = [
        AnswerDraft(question: ref("q-yesno", "Are you working?", .yesNo), value: .options(["Yes"])),
        AnswerDraft(question: ref("q-tokens", "What are you doing?", .tokens), value: .tokens(["Testing", "Coding"])),
        AnswerDraft(question: ref("q-number", "How many coffees did you have today?", .number), value: .number("2")),
        AnswerDraft(question: ref("q-note", "What did you learn today?", .note), value: .note("ReportBuilder works")),
        AnswerDraft(question: ref("q-location", "Where are you?", .location), value: .location(text: "Home")),
        AnswerDraft(question: ref("q-people", "Who are you with?", .people), value: .skipped),
    ]

    let tz = TimeZone(identifier: "America/New_York")!
    let report = try ReportBuilder.save(kind: .regular, trigger: .manual,
                                        date: Date(timeIntervalSince1970: 1_780_000_000),
                                        timeZone: tz, outcomes: outcomes,
                                        answers: answers, in: context)

    #expect(report.battery == 0.42)
    #expect(report.audio?.avg == -50)
    #expect(report.altitudeMeters == 63.0)
    #expect(report.connectionType == .wifi)
    #expect(report.focus?.isFocused == true)
    #expect(report.weather == nil) // unavailable → absent
    // Two health outcomes merge into one array.
    #expect(Set(report.health.map(\.type)) == ["steps", "heartRateAvg"])
    #expect(report.timeZoneIdentifier == "America/New_York")

    // Skipped answers still record a Response with no payload (v1 semantics).
    #expect(report.responses?.count == 6)
    let byPrompt = Dictionary(uniqueKeysWithValues: (report.responses ?? []).map { ($0.questionPrompt, $0) })
    #expect(byPrompt["Are you working?"]?.answeredOptions == ["Yes"])
    #expect(byPrompt["What are you doing?"]?.tokens?.map(\.text) == ["Testing", "Coding"])
    #expect(byPrompt["How many coffees did you have today?"]?.numericResponse == "2")
    #expect(byPrompt["What did you learn today?"]?.textResponses?.first?.text == "ReportBuilder works")
    #expect(byPrompt["Where are you?"]?.locationResponse?.text == "Home")
    let skipped = try #require(byPrompt["Who are you with?"])
    #expect(skipped.tokens == nil && skipped.answeredOptions == nil)
    #expect(skipped.questionIdentifier == "q-people")

    // Vocabulary rebuilt after save.
    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    #expect(Set(tokens.map(\.text)).isSuperset(of: ["Testing", "Coding"]))
}

@Test func emptyOptionsProducePayloadlessResponse() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let answers: [AnswerDraft] = [
        AnswerDraft(question: ref("q-empty-opts", "Working?", .yesNo), value: .options([])),
        AnswerDraft(question: ref("q-empty-tokens", "Doing?", .tokens), value: .tokens([])),
    ]
    let report = try ReportBuilder.save(kind: .regular, trigger: .manual, date: Date(),
                                        timeZone: .current, outcomes: [:],
                                        answers: answers, in: context)
    #expect(report.responses?.count == 2)
    for response in report.responses ?? [] {
        #expect(response.answeredOptions == nil)
        #expect(response.tokens == nil)
    }
}

@Test func lastReportDateReturnsMostRecent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    #expect(DispatchStore.lastReportDate(in: context) == nil)

    let older = Report(); older.date = Date(timeIntervalSince1970: 1_000)
    let newer = Report(); newer.date = Date(timeIntervalSince1970: 2_000)
    context.insert(older); context.insert(newer)
    try context.save()
    #expect(DispatchStore.lastReportDate(in: context) == Date(timeIntervalSince1970: 2_000))
}

@Test func savesPromptGroupIDWhenProvidedAndNilByDefault() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let grouped = try ReportBuilder.save(kind: .regular, trigger: .notification, date: Date(),
                                         timeZone: .current, outcomes: [:], answers: [],
                                         in: context, promptGroupID: "pg-1")
    #expect(grouped.promptGroupID == "pg-1")

    let plain = try ReportBuilder.save(kind: .regular, trigger: .manual, date: Date(),
                                       timeZone: .current, outcomes: [:], answers: [],
                                       in: context)
    #expect(plain.promptGroupID == nil)
}

/// Plan-26: a captured media payload lands on report.media.
@Test func mediaOutcomeLandsOnReport() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let sample = MediaSample(source: .spotify, title: "Song 2", artist: "Blur")
    let report = try ReportBuilder.save(
        kind: .regular, trigger: .manual, date: .now, timeZone: .current,
        outcomes: [.media: .captured(.media(sample))], answers: [], in: context)
    #expect(report.media == sample)
}
