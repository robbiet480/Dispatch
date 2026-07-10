import Foundation
import Testing
@testable import DispatchKit

// DigestSchedule owns the deterministic next-fire math for the configurable
// digest reminders (plan 40): weekly (Calendar weekday convention), monthly
// (day 1–31 clamped to the month's length), and quarterly (the chosen day in
// each calendar-quarter START month — Jan/Apr/Jul/Oct). All math takes an
// injected Calendar; DST cases pin America/New_York.

private func gregorian(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private var utc: Calendar { gregorian("UTC") }
private var eastern: Calendar { gregorian("America/New_York") }

private func moment(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                    _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute))!
}

private func ymdhm(_ calendar: Calendar, _ date: Date)
    -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
}

// MARK: - Weekly next-fire

@Test func weeklyFiresTheComingSunday() {
    // Jan 6 2027 is a Wednesday.
    let schedule = DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 1, 6, 10, 0), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 1, 10, 19, 0)) // Sunday Jan 10
}

@Test func weeklyFromExactFireRollsToNextWeek() {
    let schedule = DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 1, 10, 19, 0), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 1, 17, 19, 0)) // strictly after → next Sunday
}

// MARK: - Monthly clamping

@Test func monthlyDay31ClampsToFebruaryLastDay() {
    let schedule = DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 2, 1), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 2, 28, 19, 0)) // 2027 not a leap year
}

@Test func monthlyDay31AdvancesToMarch31AfterFebruary() {
    let schedule = DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 2, 28, 19, 0), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 3, 31, 19, 0))
}

@Test func monthlyFromPastTodaysFireSkipsToNextMonthClamped() {
    let schedule = DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                                  hour: 19, minute: 0, isEnabled: true)
    // Jan 31 19:01 — today's 19:00 fire already passed.
    let next = schedule.nextFireDate(after: moment(utc, 2027, 1, 31, 19, 1), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 2, 28, 19, 0))
}

// MARK: - Quarterly anchors

@Test func quarterlyAnchorsToNextQuarterStartMonth() {
    let schedule = DigestSchedule(id: UUID(), cadence: .quarterly(dayOfMonth: 5),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 2, 10), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 4, 5, 19, 0)) // Jan passed, next anchor Apr
}

@Test func quarterlyWrapsToJanuaryNextYear() {
    let schedule = DigestSchedule(id: UUID(), cadence: .quarterly(dayOfMonth: 5),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 12, 20), calendar: utc)
    #expect(ymdhm(utc, next!) == (2028, 1, 5, 19, 0))
}

@Test func quarterlyClampsDayInsideAnchorMonth() {
    let schedule = DigestSchedule(id: UUID(), cadence: .quarterly(dayOfMonth: 31),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(utc, 2027, 2, 10), calendar: utc)
    #expect(ymdhm(utc, next!) == (2027, 4, 30, 19, 0)) // Apr has 30 days
}

// MARK: - DST (mandatory)

@Test func weeklyKeepsWallClockAcrossSpringForward() {
    // Spring-forward in America/New_York is 2027-03-14 02:00 → 03:00.
    let schedule = DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                                  hour: 19, minute: 0, isEnabled: true)
    let next = schedule.nextFireDate(after: moment(eastern, 2027, 3, 10, 12, 0),
                                     calendar: eastern)
    // Wall-clock 19:00 holds even though the UTC offset shifts EST→EDT.
    #expect(ymdhm(eastern, next!) == (2027, 3, 14, 19, 0))
}

@Test func weeklyIntoNonexistentHourResolvesForward() {
    // 02:30 on 2027-03-14 does not exist (clocks jump 02:00→03:00). The
    // .nextTime policy rolls forward to the next valid instant — never nil,
    // never a double-fire.
    let schedule = DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                                  hour: 2, minute: 30, isEnabled: true)
    let now = moment(eastern, 2027, 3, 13, 12, 0) // Saturday before
    let next = schedule.nextFireDate(after: now, calendar: eastern)
    #expect(next != nil)
    #expect(next! > now)
    let stamp = ymdhm(eastern, next!)
    #expect(stamp.year == 2027 && stamp.month == 3 && stamp.day == 14)
}

// MARK: - repeatingTriggerComponents

@Test func repeatingComponentsWeekly() {
    let schedule = DigestSchedule(id: UUID(), cadence: .weekly(weekday: 3),
                                  hour: 8, minute: 15, isEnabled: true)
    #expect(schedule.repeatingTriggerComponents
        == DateComponents(hour: 8, minute: 15, weekday: 3))
}

@Test func repeatingComponentsMonthlyWithinFirst28Days() {
    let schedule = DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 15),
                                  hour: 9, minute: 0, isEnabled: true)
    #expect(schedule.repeatingTriggerComponents
        == DateComponents(day: 15, hour: 9, minute: 0))
}

@Test func repeatingComponentsNilForClampingAndQuarterly() {
    let monthly31 = DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                                   hour: 9, minute: 0, isEnabled: true)
    let quarterly = DigestSchedule(id: UUID(), cadence: .quarterly(dayOfMonth: 1),
                                   hour: 9, minute: 0, isEnabled: true)
    #expect(monthly31.repeatingTriggerComponents == nil)
    #expect(quarterly.repeatingTriggerComponents == nil)
}

// MARK: - Codable round-trip (this IS the persistence format)

@Test func codableRoundTripAllCadences() throws {
    let schedules = [
        DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                       hour: 19, minute: 0, isEnabled: true),
        DigestSchedule(id: UUID(), cadence: .monthly(dayOfMonth: 31),
                       hour: 9, minute: 30, isEnabled: false),
        DigestSchedule(id: UUID(), cadence: .quarterly(dayOfMonth: 5),
                       hour: 8, minute: 0, isEnabled: true),
    ]
    let data = try JSONEncoder().encode(schedules)
    let decoded = try JSONDecoder().decode([DigestSchedule].self, from: data)
    #expect(decoded == schedules)
}

// MARK: - Cadence.period

@Test func cadencePeriodMapping() {
    #expect(DigestSchedule.Cadence.weekly(weekday: 1).period == .week)
    #expect(DigestSchedule.Cadence.monthly(dayOfMonth: 15).period == .month)
    #expect(DigestSchedule.Cadence.quarterly(dayOfMonth: 5).period == .quarter)
}

// MARK: - DigestPeriod.interval

@Test func weekIntervalReproducesDigestStatsWindow() {
    // The exact plan-14 arithmetic: 7 days ending the day after `ending`.
    let ending = moment(utc, 2027, 3, 15, 12, 0)
    let window = DigestPeriod.week.interval(ending: ending, calendar: utc)
    #expect(window.end == moment(utc, 2027, 3, 16)) // day after, start of day
    #expect(window.start == moment(utc, 2027, 3, 9))
    #expect(window.priorStart == moment(utc, 2027, 3, 2))
}

@Test func monthIntervalSpansOneCalendarMonth() {
    let ending = moment(utc, 2027, 3, 15, 12, 0)
    let window = DigestPeriod.month.interval(ending: ending, calendar: utc)
    #expect(window.end == moment(utc, 2027, 3, 16))
    #expect(window.start == moment(utc, 2027, 2, 16))
    #expect(window.priorStart == moment(utc, 2027, 1, 16))
}

@Test func quarterIntervalSpansThreeCalendarMonths() {
    let ending = moment(utc, 2027, 3, 15, 12, 0)
    let window = DigestPeriod.quarter.interval(ending: ending, calendar: utc)
    #expect(window.end == moment(utc, 2027, 3, 16))
    #expect(window.start == moment(utc, 2026, 12, 16))
    #expect(window.priorStart == moment(utc, 2026, 9, 16))
}
