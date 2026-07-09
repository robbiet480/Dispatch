import Foundation
import Testing
@testable import DispatchKit

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 2026-06-15 12:00:00 UTC (a Monday).
private let noon = Date(timeIntervalSince1970: 1_781_524_800)

private func report(daysAgo: Int, hour: Int = 10, isDraft: Bool = false) -> Report {
    let calendar = utcCalendar
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: noon))!
    let report = Report()
    report.date = calendar.date(byAdding: .hour, value: hour, to: day)!
    report.isDraft = isDraft
    return report
}

// MARK: - ReportStreak

@Test func streakCountsConsecutiveDaysEndingToday() {
    let reports = [report(daysAgo: 0), report(daysAgo: 1), report(daysAgo: 2), report(daysAgo: 4)]
    #expect(ReportStreak.days(reports: reports, now: noon, calendar: utcCalendar) == 3)
}

@Test func streakSurvivesMissingToday() {
    // No report yet today — streak through yesterday still counts.
    let reports = [report(daysAgo: 1), report(daysAgo: 2)]
    #expect(ReportStreak.days(reports: reports, now: noon, calendar: utcCalendar) == 2)
}

@Test func streakZeroWhenLastReportTwoDaysAgo() {
    let reports = [report(daysAgo: 2), report(daysAgo: 3)]
    #expect(ReportStreak.days(reports: reports, now: noon, calendar: utcCalendar) == 0)
}

@Test func streakIgnoresDrafts() {
    let reports = [report(daysAgo: 0, isDraft: true), report(daysAgo: 1)]
    #expect(ReportStreak.days(reports: reports, now: noon, calendar: utcCalendar) == 1)
}

@Test func streakEmptyReportsIsZero() {
    #expect(ReportStreak.days(reports: [], now: noon, calendar: utcCalendar) == 0)
}

// MARK: - WidgetSnapshot.compute

@Test func computeAggregatesTodayCountLastDateAndStreak() {
    let morning = report(daysAgo: 0, hour: 8)
    let late = report(daysAgo: 0, hour: 11)
    let yesterday = report(daysAgo: 1)
    let prompt = noon.addingTimeInterval(3600)

    let snapshot = WidgetSnapshot.compute(reports: [morning, late, yesterday],
                                          nextPromptDate: prompt, now: noon, calendar: utcCalendar)

    #expect(snapshot.todayCount == 2)
    #expect(snapshot.lastReportDate == late.date)
    #expect(snapshot.streakDays == 2)
    #expect(snapshot.nextPromptDate == prompt)
}

@Test func computeExcludesDrafts() {
    let draft = report(daysAgo: 0, hour: 11, isDraft: true)
    let filed = report(daysAgo: 0, hour: 8)

    let snapshot = WidgetSnapshot.compute(reports: [draft, filed], now: noon, calendar: utcCalendar)

    #expect(snapshot.todayCount == 1)
    #expect(snapshot.lastReportDate == filed.date)
}

@Test func computeEmptyReportsGivesPlaceholderValues() {
    let snapshot = WidgetSnapshot.compute(reports: [], now: noon, calendar: utcCalendar)
    #expect(snapshot == WidgetSnapshot())
}

@Test func snapshotRoundTripsThroughJSON() throws {
    let snapshot = WidgetSnapshot(lastReportDate: noon, todayCount: 3,
                                  streakDays: 7, nextPromptDate: noon.addingTimeInterval(600))
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
    #expect(decoded == snapshot)
}
