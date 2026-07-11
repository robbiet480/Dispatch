import Foundation
import Testing
@testable import DispatchKit

private func date(_ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "GMT")!
    return cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: h, minute: mi, second: s))!
}

private func candidate(
    end: Date, isAllDay: Bool = false, calendarID: String? = "cal-1", title: String? = "Event"
) -> CalendarEventCandidate {
    CalendarEventCandidate(end: end, isAllDay: isAllDay, calendarID: calendarID, title: title)
}

// MARK: - Rule matching

@Test func allEventsRuleMatchesAnything() {
    let rule = CalendarEventMatchRule.allEvents
    #expect(rule.matches(calendarID: "cal-1", title: "Standup"))
    #expect(rule.matches(calendarID: nil, title: nil))
}

@Test func calendarsRuleMatchesByIdentifierAndRejectsNilOrMismatch() {
    let rule = CalendarEventMatchRule.calendars(["cal-1", "cal-2"])
    #expect(rule.matches(calendarID: "cal-1", title: nil))
    #expect(rule.matches(calendarID: "cal-2", title: "anything"))
    #expect(!rule.matches(calendarID: "cal-3", title: nil))
    #expect(!rule.matches(calendarID: nil, title: nil))
}

@Test func emptyCalendarsRuleMatchesNothing() {
    // Degenerate config fails safe (prevented at the editor, but storage-level
    // it must never fire rather than fire for everything).
    let rule = CalendarEventMatchRule.calendars([])
    #expect(!rule.matches(calendarID: "cal-1", title: nil))
}

@Test func titleContainsIsCaseAndDiacriticInsensitive() {
    let rule = CalendarEventMatchRule.titleContains("Standup")
    #expect(rule.matches(calendarID: nil, title: "daily standup"))
    #expect(rule.matches(calendarID: nil, title: "STANDÜP"))
    #expect(!rule.matches(calendarID: nil, title: "retro"))
    #expect(!rule.matches(calendarID: nil, title: nil))
}

// MARK: - Raw-kind codec

@Test func matchRuleRoundTripsThroughStorageRaws() throws {
    let calendars = CalendarEventMatchRule.calendars(["cal-1", "cal-2"])
    let decoded = CalendarEventMatchRule(
        kindRaw: calendars.kindRaw,
        identifiersJSON: calendars.identifiersJSON,
        titleFilter: calendars.titleFilter)
    #expect(decoded == calendars)

    let title = CalendarEventMatchRule.titleContains("standup")
    let decodedTitle = CalendarEventMatchRule(
        kindRaw: title.kindRaw,
        identifiersJSON: title.identifiersJSON,
        titleFilter: title.titleFilter)
    #expect(decodedTitle == title)

    // nil kind raw is the .allEvents storage form (the setter nils the fields).
    #expect(CalendarEventMatchRule(kindRaw: nil, identifiersJSON: nil, titleFilter: nil) == .allEvents)
    // Unknown kind raws (future rule from a newer build) resolve to nil so the
    // caller can fall back to .disabled — never fires rather than misfires.
    #expect(CalendarEventMatchRule(kindRaw: "futureRule", identifiersJSON: nil, titleFilter: nil) == nil)
}

// MARK: - Fire dates

@Test func fireDatesExcludeAllDayEvents() {
    let dates = CalendarEventPlanner.fireDates(
        candidates: [candidate(end: date(15), isAllDay: true), candidate(end: date(16))],
        rule: .allEvents, now: date(14), windowStart: date(8), windowEnd: date(24, 0))
    #expect(dates == [date(16)])
}

@Test func fireDatesExcludeEndsAtOrBeforeNow() {
    let now = date(14)
    let dates = CalendarEventPlanner.fireDates(
        candidates: [candidate(end: date(13)), candidate(end: now), candidate(end: date(15))],
        rule: .allEvents, now: now, windowStart: date(8), windowEnd: date(24, 0))
    // An in-progress event (end still in the future) IS included; ended ones are not.
    #expect(dates == [date(15)])
}

@Test func fireDatesExcludeEndsOutsideWindow() {
    let dates = CalendarEventPlanner.fireDates(
        candidates: [candidate(end: date(7)), candidate(end: date(9)), candidate(end: date(12))],
        rule: .allEvents, now: date(6), windowStart: date(8), windowEnd: date(12))
    // windowEnd is exclusive; before windowStart is out.
    #expect(dates == [date(9)])
}

@Test func fireDatesApplyTheMatchRule() {
    let dates = CalendarEventPlanner.fireDates(
        candidates: [
            candidate(end: date(15), title: "Daily standup"),
            candidate(end: date(16), title: "Focus block"),
        ],
        rule: .titleContains("standup"),
        now: date(14), windowStart: date(8), windowEnd: date(24, 0))
    #expect(dates == [date(15)])
}

@Test func fireDatesDedupeAtMinuteGranularityAndSortAscending() {
    let dates = CalendarEventPlanner.fireDates(
        candidates: [
            candidate(end: date(17, 30, 40)),
            candidate(end: date(15)),
            candidate(end: date(17, 30, 10)),
        ],
        rule: .allEvents, now: date(14), windowStart: date(8), windowEnd: date(24, 0))
    // The gprompt stamp is minute-resolution: two events ending in the same
    // minute produce ONE prompt (the earliest end in that minute), sorted.
    #expect(dates == [date(15), date(17, 30, 10)])
}
