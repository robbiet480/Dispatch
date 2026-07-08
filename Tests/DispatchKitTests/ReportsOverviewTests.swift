import Foundation
import Testing
@testable import DispatchKit

private func report(_ iso: String, tz: String) -> Report {
    let r = Report()
    let f = ISO8601DateFormatter()
    r.date = f.date(from: iso)!
    r.timeZoneIdentifier = tz
    return r
}

@Test func groupsByReportLocalDay() {
    // 23:30 New York on Dec 12 == 04:30 UTC Dec 13. Grouped by NY day.
    let late = report("2018-12-13T04:30:00Z", tz: "America/New_York")
    let noon = report("2018-12-12T17:00:00Z", tz: "America/New_York")
    let sections = ReportsOverview.sections(from: [late, noon])
    #expect(sections.count == 1)
    #expect(sections[0].weekday == "WEDNESDAY")
    #expect(sections[0].dateLabel == "DEC 12, 2018")
    #expect(sections[0].reports.first?.date == late.date) // newest first within day
}

@Test func sectionsNewestDayFirst() {
    let old = report("2017-11-16T18:00:00Z", tz: "America/Los_Angeles")
    let new = report("2018-12-13T18:00:00Z", tz: "America/Los_Angeles")
    let sections = ReportsOverview.sections(from: [old, new])
    #expect(sections.count == 2)
    #expect(sections[0].dateLabel == "DEC 13, 2018")
    #expect(sections[1].dateLabel == "NOV 16, 2017")
}

@Test func statsCountDistinctDaysWithReports() {
    let a = report("2018-12-12T17:00:00Z", tz: "UTC")
    let b = report("2018-12-12T18:00:00Z", tz: "UTC")
    let c = report("2018-12-14T18:00:00Z", tz: "UTC")
    let stats = ReportsOverview.stats(from: [a, b, c])
    #expect(stats.reports == 3)
    #expect(stats.days == 2)          // the empty Dec 13 doesn't count
    #expect(stats.avgPerDay == 1.5)
    let empty = ReportsOverview.stats(from: [])
    #expect(empty.reports == 0 && empty.days == 0 && empty.avgPerDay == 0)
}

@Test func secondaryStatsCountDistinctPlaces() {
    let r1 = report("2018-12-12T17:00:00Z", tz: "UTC")
    let resp1 = Response(); var loc1 = LocationAnswer(); loc1.text = "The Plaza"; loc1.foursquareVenueId = "v1"
    resp1.locationResponse = loc1; resp1.report = r1
    let r2 = report("2018-12-13T17:00:00Z", tz: "UTC")
    let resp2 = Response(); var loc2 = LocationAnswer(); loc2.text = "The Plaza again"; loc2.foursquareVenueId = "v1"
    resp2.locationResponse = loc2; resp2.report = r2
    r1.responses = [resp1]; r2.responses = [resp2]
    let stats = ReportsOverview.secondaryStats(reports: [r1, r2], tokenCount: 41, personCount: 18)
    #expect(stats.tokens == 41)
    #expect(stats.locations == 1) // same venue id
    #expect(stats.people == 18)
}
