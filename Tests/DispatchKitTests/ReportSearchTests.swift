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
    #expect(filtered.first?.responses?.first?.textResponses?.first?.text == "Coffee")
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

/// Mac dashboard regression (review fix): the visualization aggregates must
/// be built from the SEARCH-FILTERED report set — the same set the sidebar
/// stats count — never the all-reports set. Pins the kit-side composition
/// (ReportSearch.filter → ReportsOverview.stats / VisualizationData.build)
/// so both surfaces agree on what "2 reports" means.
@Test func searchFilteredReportsDriveStatsAndVisualizationsConsistently() throws {
    let question = Question()
    question.uniqueIdentifier = "q-working"
    question.prompt = "Are you working?"
    question.type = .yesNo
    question.choices = ["Yes", "No"]

    func makeReport(note: String, answer: String) -> Report {
        let report = Report()
        report.date = Date()
        let noteResponse = Response()
        noteResponse.textResponses = [TokenValue(text: note)]
        noteResponse.report = report
        let answerResponse = Response()
        answerResponse.questionIdentifier = "q-working"
        answerResponse.answeredOptions = [answer]
        answerResponse.report = report
        report.responses = [noteResponse, answerResponse]
        return report
    }

    let reports = [
        makeReport(note: "Coffee run", answer: "Yes"),
        makeReport(note: "Coffee break", answer: "No"),
        makeReport(note: "Gym", answer: "Yes"),
        makeReport(note: "Gym again", answer: "Yes"),
    ]

    let searched = ReportSearch.filter(reports, query: "coffee")
    #expect(searched.count == 2)

    // The stat tiles and the charts consume the same filtered set.
    let stats = ReportsOverview.stats(from: searched)
    #expect(stats.reports == 2)

    guard case .optionShares(let shares) = VisualizationData.build(for: question, reports: searched)
    else {
        Issue.record("expected optionShares")
        return
    }
    // Only the two "coffee" reports contribute: one Yes, one No — 50/50.
    // The all-reports set would read 75/25.
    #expect(shares.count == 2)
    #expect(shares.first(where: { $0.option == "Yes" })?.share == 0.5)
    #expect(shares.first(where: { $0.option == "No" })?.share == 0.5)
}

/// Mac dashboard scope (MacDashboardView.filteredReports): the sidebar search
/// (ReportSearch.filter) and the visualization-filter criteria (ReportFilter)
/// COMPOSE — both applied together, search first. Pins that a report matching
/// the search but failing a criterion is excluded, and vice-versa, using the
/// same public kit APIs the view calls. ReportSearchTests and ReportFilterTests
/// pin each stage alone; this pins their intersection.
@Test func searchAndCriteriaComposeLikeMacDashboard() throws {
    func makeReport(note: String, place: String) -> Report {
        let report = Report()
        report.date = Date()
        let noteResponse = Response()
        noteResponse.textResponses = [TokenValue(text: note)]
        noteResponse.report = report
        let placeResponse = Response()
        var answer = LocationAnswer()
        answer.text = place
        placeResponse.locationResponse = answer
        placeResponse.report = report
        report.responses = [noteResponse, placeResponse]
        return report
    }

    // Two axes: the note carries the search term "coffee"; the place carries
    // the filter criterion .place("Office").
    let both = makeReport(note: "Coffee run", place: "Office")       // search ✓ criterion ✓
    let searchOnly = makeReport(note: "Coffee break", place: "Home") // search ✓ criterion ✗
    let criterionOnly = makeReport(note: "Tea time", place: "Office")// search ✗ criterion ✓
    let neither = makeReport(note: "Tea time", place: "Home")        // search ✗ criterion ✗
    let reports = [both, searchOnly, criterionOnly, neither]

    // Mirror filteredReports(): ReportSearch.filter, THEN ReportFilter.matches
    // over the searched set with the dashboard's criteria.
    let criteria: [ReportFilter.FilterCriterion] = [.place("Office")]
    let searched = ReportSearch.filter(reports, query: "coffee")
    #expect(searched.count == 2) // both + searchOnly

    let composed = searched.filter {
        ReportFilter.matches(report: $0, criteria: criteria)
    }

    // Only the report satisfying BOTH survives the composition.
    #expect(composed.count == 1)
    #expect(composed.first === both)
    // A report matching the search but failing the criterion is excluded…
    #expect(!composed.contains { $0 === searchOnly })
    // …and one matching the criterion but not the search never reaches it.
    #expect(!composed.contains { $0 === criterionOnly })
    #expect(!composed.contains { $0 === neither })
}
