import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func matchesNoteText() throws {
    let report = Report()
    let response = Response()
    response.textResponses = [TokenValue(text: "I visited the plaza")]
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "plaza"))
    #expect(ReportSearch.matches(report, query: "visited"))
    #expect(ReportSearch.matches(report, query: "I visited the plaza"))
    #expect(!ReportSearch.matches(report, query: "mall"))
}

@Test func caseInsensitiveMatching() throws {
    let report = Report()
    let response = Response()
    response.textResponses = [TokenValue(text: "The Plaza")]
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "plaza"))
    #expect(ReportSearch.matches(report, query: "PLAZA"))
    #expect(ReportSearch.matches(report, query: "PlAzA"))
}

@Test func diacriticInsensitiveMatching() throws {
    let report = Report()
    let response = Response()
    response.textResponses = [TokenValue(text: "café")]
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "cafe"))
    #expect(ReportSearch.matches(report, query: "CAFE"))
    #expect(ReportSearch.matches(report, query: "café"))
}

@Test func matchesTokenTexts() throws {
    let report = Report()
    let response = Response()
    response.tokens = [TokenValue(text: "Coding"), TokenValue(text: "Testing")]
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "Coding"))
    #expect(ReportSearch.matches(report, query: "testing"))
    #expect(!ReportSearch.matches(report, query: "Running"))
}

@Test func matchesPeopleTokens() throws {
    let report = Report()
    let response = Response()
    response.tokens = [TokenValue(text: "Alice Smith"), TokenValue(text: "Bob Johnson")]
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "alice"))
    #expect(ReportSearch.matches(report, query: "smith"))
    #expect(ReportSearch.matches(report, query: "bob"))
    #expect(!ReportSearch.matches(report, query: "charlie"))
}

@Test func matchesLocationAnswerText() throws {
    let report = Report()
    let response = Response()
    var answer = LocationAnswer()
    answer.text = "Coffee Shop Downtown"
    response.locationResponse = answer
    response.report = report
    report.responses = [response]

    #expect(ReportSearch.matches(report, query: "coffee"))
    #expect(ReportSearch.matches(report, query: "downtown"))
    #expect(!ReportSearch.matches(report, query: "hotel"))
}

@Test func matchesPlacemarkLocalityAndName() throws {
    let report = Report()
    var location = LocationSnapshot()
    var placemark = Placemark()
    placemark.locality = "San Francisco"
    placemark.name = "Golden Gate Park"
    location.placemark = placemark
    report.location = location

    #expect(ReportSearch.matches(report, query: "san francisco"))
    #expect(ReportSearch.matches(report, query: "golden gate"))
    #expect(ReportSearch.matches(report, query: "francisco"))
    #expect(!ReportSearch.matches(report, query: "los angeles"))
}

@Test func emptyQueryMatchesAll() throws {
    let report = Report()

    #expect(ReportSearch.matches(report, query: ""))
    #expect(ReportSearch.matches(report, query: "   "))
    #expect(ReportSearch.matches(report, query: "\t\n"))
}

@Test func nonMatchingQueryExcluded() throws {
    let report = Report()
    let response = Response()
    response.textResponses = [TokenValue(text: "Working")]
    response.report = report
    report.responses = [response]

    #expect(!ReportSearch.matches(report, query: "sleeping"))
    #expect(!ReportSearch.matches(report, query: "xyz"))
}

@Test func filterReportsReturnsMatches() throws {
    let reports = [
        { () -> Report in
            let r = Report()
            let resp = Response()
            resp.textResponses = [TokenValue(text: "Meeting")]
            resp.report = r
            r.responses = [resp]
            return r
        }(),
        { () -> Report in
            let r = Report()
            let resp = Response()
            resp.textResponses = [TokenValue(text: "Coffee")]
            resp.report = r
            r.responses = [resp]
            return r
        }(),
        { () -> Report in
            let r = Report()
            return r
        }(),
    ]

    let filtered = ReportSearch.filter(reports, query: "coffee")
    #expect(filtered.count == 1)
    #expect(filtered.first?.responses.first?.textResponses?.first?.text == "Coffee")
}

@Test func filterWithEmptyQueryReturnsAll() throws {
    let reports = [
        { () -> Report in
            let r = Report()
            let resp = Response()
            resp.textResponses = [TokenValue(text: "Meeting")]
            resp.report = r
            r.responses = [resp]
            return r
        }(),
        { () -> Report in
            let r = Report()
            let resp = Response()
            resp.textResponses = [TokenValue(text: "Coffee")]
            resp.report = r
            r.responses = [resp]
            return r
        }(),
    ]

    let filtered = ReportSearch.filter(reports, query: "")
    #expect(filtered.count == 2)
}

@Test func isBackdatedPersistsThroughSave() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let answers: [AnswerDraft] = []
    let report = try ReportBuilder.save(
        kind: .regular,
        trigger: .manual,
        date: Date(),
        timeZone: .current,
        outcomes: [:],
        answers: answers,
        in: context,
        isBackdated: true
    )

    #expect(report.isBackdated == true)

    // Verify it persists after a fresh fetch
    let reportId = report.uniqueIdentifier
    var descriptor = FetchDescriptor<Report>()
    descriptor.predicate = #Predicate<Report> { $0.uniqueIdentifier == reportId }
    let fetched = try context.fetch(descriptor)
    #expect(fetched.first?.isBackdated == true)
}

@Test func isBackdatedDefaultsFalse() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let answers: [AnswerDraft] = []
    let report = try ReportBuilder.save(
        kind: .regular,
        trigger: .manual,
        date: Date(),
        timeZone: .current,
        outcomes: [:],
        answers: answers,
        in: context
    )

    #expect(report.isBackdated == false)
}
