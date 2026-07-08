import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func insertsAndFetchesModels() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let question = Question()
    question.uniqueIdentifier = "q-yesno"
    question.prompt = "Are you working?"
    question.type = .yesNo
    question.reportKinds = [.regular, .wake]
    context.insert(question)

    let report = Report()
    report.uniqueIdentifier = "snap-1"
    report.date = Date(timeIntervalSince1970: 1_455_235_734)
    report.timeZoneIdentifier = "GMT-0400"
    report.kind = .regular
    report.trigger = .manual
    report.audio = AudioSample(avg: -43.57, peak: -34.0)
    report.health = [HealthReading(type: "steps", value: 481, unit: "count")]
    report.focus = FocusState(label: "Work", isFocused: true)
    context.insert(report)

    let response = Response()
    response.uniqueIdentifier = "r-1b"
    response.questionPrompt = "Are you working?"
    response.answeredOptions = ["Yes"]
    response.report = report
    context.insert(response)
    try context.save()

    let reports = try context.fetch(FetchDescriptor<Report>())
    #expect(reports.count == 1)
    let fetched = try #require(reports.first)
    #expect(fetched.audio?.avg == -43.57)
    #expect(fetched.health.first?.value == 481)
    #expect(fetched.focus?.label == "Work")
    #expect(fetched.responses.count == 1)
    #expect(fetched.responses.first?.answeredOptions == ["Yes"])

    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.first?.type == .yesNo)
    #expect(questions.first?.reportKinds == [.regular, .wake])
}

@Test func cascadeDeletesResponses() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    let response = Response()
    response.report = report
    context.insert(report)
    context.insert(response)
    try context.save()

    context.delete(report)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Response>()).isEmpty)
}
