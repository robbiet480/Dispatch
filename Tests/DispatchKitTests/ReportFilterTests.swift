import Foundation
import Testing
@testable import DispatchKit

private func makeReport(date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                        timeZone: String = "GMT") -> Report {
    let report = Report()
    report.date = date
    report.timeZoneIdentifier = timeZone
    return report
}

private func attachTokens(_ texts: [String], questionIdentifier: String? = nil, to report: Report) {
    let response = Response()
    response.questionIdentifier = questionIdentifier
    response.tokens = texts.map { TokenValue(text: $0) }
    response.report = report
    report.responses = (report.responses ?? []) + [response]
}

@Test func personCriterionMatchesPeopleResponses() {
    let report = makeReport()
    attachTokens(["Ada"], questionIdentifier: "q-people", to: report)
    attachTokens(["coding"], questionIdentifier: "q-tokens", to: report)

    #expect(ReportFilter.matches(report: report, criteria: [.person("Ada")],
                                 peopleQuestionIDs: ["q-people"]))
    #expect(ReportFilter.matches(report: report, criteria: [.person("ada")],
                                 peopleQuestionIDs: ["q-people"]))
    // Scoped to people questions: a token with the same text must not match.
    #expect(!ReportFilter.matches(report: report, criteria: [.person("coding")],
                                  peopleQuestionIDs: ["q-people"]))
    #expect(!ReportFilter.matches(report: report, criteria: [.person("Grace")],
                                  peopleQuestionIDs: ["q-people"]))
}

@Test func tokenCriterionMatchesAnyTokenText() {
    let report = makeReport()
    attachTokens(["coding", "coffee"], to: report)
    #expect(ReportFilter.matches(report: report, criteria: [.token("Coffee")]))
    #expect(!ReportFilter.matches(report: report, criteria: [.token("tea")]))
}

@Test func placeCriterionMatchesAnsweredAndSensedPlaces() {
    let answered = makeReport()
    let response = Response()
    var locationAnswer = LocationAnswer()
    locationAnswer.text = "Office"
    response.locationResponse = locationAnswer
    response.report = answered
    answered.responses = (answered.responses ?? []) + [response]
    #expect(ReportFilter.matches(report: answered, criteria: [.place("Office")]))
    #expect(!ReportFilter.matches(report: answered, criteria: [.place("Home")]))

    let sensed = makeReport()
    var snapshot = LocationSnapshot()
    var placemark = Placemark()
    placemark.name = "Blue Bottle"
    snapshot.placemark = placemark
    sensed.location = snapshot
    #expect(ReportFilter.matches(report: sensed, criteria: [.place("Blue Bottle")]))
}

@Test func monthAndYearCriteriaUseReportTimeZone() {
    // 2023-12-31 23:30 GMT is already 2024-01-01 in GMT+2.
    let date = ISO8601DateFormatter().date(from: "2023-12-31T23:30:00Z")!
    let gmtReport = makeReport(date: date, timeZone: "GMT")
    #expect(ReportFilter.matches(report: gmtReport, criteria: [.month(12), .year(2023)]))
    #expect(!ReportFilter.matches(report: gmtReport, criteria: [.month(1)]))

    let aheadReport = makeReport(date: date, timeZone: "Etc/GMT-2")
    #expect(ReportFilter.matches(report: aheadReport, criteria: [.month(1), .year(2024)]))
}

@Test func ambientAudioCriterionBucketsByDisplayThresholds() {
    let report = makeReport()
    report.audio = AudioSample(avg: -43.57, peak: -34.0) // display ≈ 42.9 → quiet
    #expect(ReportFilter.matches(report: report, criteria: [.ambientAudio(.quiet)]))
    #expect(!ReportFilter.matches(report: report, criteria: [.ambientAudio(.loud)]))

    report.audio = AudioSample(avg: -35, peak: -20) // display 60 → moderate
    #expect(ReportFilter.matches(report: report, criteria: [.ambientAudio(.moderate)]))

    report.audio = AudioSample(avg: -10, peak: -5) // display 110 → loud
    #expect(ReportFilter.matches(report: report, criteria: [.ambientAudio(.loud)]))

    report.audio = nil
    #expect(!ReportFilter.matches(report: report, criteria: [.ambientAudio(.quiet)]))
}

@Test func stepsCriterionBuckets() {
    let report = makeReport()
    report.health = [HealthReading(type: "steps", value: 481, unit: "count")]
    #expect(ReportFilter.matches(report: report, criteria: [.steps(.under5k)]))
    #expect(!ReportFilter.matches(report: report, criteria: [.steps(.over10k)]))

    report.health = [HealthReading(type: "steps", value: 7500, unit: "count")]
    #expect(ReportFilter.matches(report: report, criteria: [.steps(.from5kTo10k)]))

    report.health = [HealthReading(type: "steps", value: 12000, unit: "count")]
    #expect(ReportFilter.matches(report: report, criteria: [.steps(.over10k)]))

    report.health = []
    #expect(!ReportFilter.matches(report: report, criteria: [.steps(.under5k)]))
}

@Test func weatherCriterionMatchesConditionString() {
    let report = makeReport()
    var weather = WeatherObservation()
    weather.condition = "Clear"
    report.weather = weather
    #expect(ReportFilter.matches(report: report, criteria: [.weather("clear")]))
    #expect(!ReportFilter.matches(report: report, criteria: [.weather("Rain")]))

    report.weather = nil
    #expect(!ReportFilter.matches(report: report, criteria: [.weather("Clear")]))
}

@Test func allCriteriaMustMatch() {
    let date = ISO8601DateFormatter().date(from: "2024-06-15T12:00:00Z")!
    let report = makeReport(date: date)
    attachTokens(["coffee"], to: report)
    report.health = [HealthReading(type: "steps", value: 6000, unit: "count")]

    // Every criterion satisfied → match.
    #expect(ReportFilter.matches(report: report, criteria: [
        .token("coffee"), .month(6), .year(2024), .steps(.from5kTo10k),
    ]))
    // One failing criterion sinks the whole match.
    #expect(!ReportFilter.matches(report: report, criteria: [
        .token("coffee"), .month(6), .year(2024), .steps(.over10k),
    ]))
    // Empty criteria match everything.
    #expect(ReportFilter.matches(report: report, criteria: []))
}

@Test func filterStorePersistsCriteriaAcrossReload() {
    let defaults = UserDefaults(suiteName: "report-filter-test-\(UUID().uuidString)")!
    let store = VisualizationFilterStore(defaults: defaults)
    #expect(store.criteria.isEmpty)

    store.addCriterion(.token("coffee"))
    store.addCriterion(.month(6))
    store.addCriterion(.token("coffee")) // duplicate ignored
    #expect(store.criteria == [.token("coffee"), .month(6)])

    let reloaded = VisualizationFilterStore(defaults: defaults)
    #expect(reloaded.criteria == [.token("coffee"), .month(6)])

    reloaded.removeCriterion(.token("coffee"))
    #expect(reloaded.criteria == [.month(6)])
    #expect(VisualizationFilterStore(defaults: defaults).criteria == [.month(6)])

    reloaded.clearCriteria()
    #expect(VisualizationFilterStore(defaults: defaults).criteria.isEmpty)
}

/// Task 6 (build-5 review): token criteria must EXCLUDE people-question
/// responses when people questions are known — a name filed under "Who are
/// you with?" is not a token. Unknown (empty) people set keeps the permissive
/// legacy behavior.
@Test func tokenCriterionExcludesPeopleResponsesWhenScoped() {
    let report = makeReport()
    attachTokens(["Ada"], questionIdentifier: "q-people", to: report)
    attachTokens(["coding"], questionIdentifier: "q-tokens", to: report)

    #expect(!ReportFilter.matches(report: report, criteria: [.token("Ada")],
                                  peopleQuestionIDs: ["q-people"]))
    #expect(ReportFilter.matches(report: report, criteria: [.token("coding")],
                                 peopleQuestionIDs: ["q-people"]))
    // Unscoped (empty set) still matches any token text.
    #expect(ReportFilter.matches(report: report, criteria: [.token("Ada")]))
}

/// Task 6 (build-5 review): canonicalKey is kind-aware and stable, so a
/// person and a token sharing display text can't collide in chip identity
/// or memo keys.
@Test func canonicalKeyIsKindAwareAndStable() {
    #expect(ReportFilter.FilterCriterion.person("Ada").canonicalKey == "person:Ada")
    #expect(ReportFilter.FilterCriterion.token("Ada").canonicalKey == "token:Ada")
    #expect(ReportFilter.FilterCriterion.person("Ada").canonicalKey
        != ReportFilter.FilterCriterion.token("Ada").canonicalKey)
    #expect(ReportFilter.FilterCriterion.month(3).canonicalKey == "month:3")
    #expect(ReportFilter.FilterCriterion.year(2026).canonicalKey == "year:2026")
    #expect(ReportFilter.FilterCriterion.ambientAudio(.quiet).canonicalKey == "ambientAudio:quiet")
    #expect(ReportFilter.FilterCriterion.steps(.over10k).canonicalKey == "steps:over10k")
    #expect(ReportFilter.FilterCriterion.weather("Clear").canonicalKey == "weather:Clear")
    // displayText collides for these two; canonicalKey must not.
    #expect(ReportFilter.FilterCriterion.person("Ada").displayText
        == ReportFilter.FilterCriterion.token("Ada").displayText)
}
