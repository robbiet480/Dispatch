import Foundation
import Testing
@testable import DispatchKit

private let calendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "GMT")!
    return cal
}()

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func group(schedule: GroupSchedule, id: String = "pg-test") -> PromptGroup {
    let g = PromptGroup()
    g.uniqueIdentifier = id
    g.schedule = schedule
    return g
}

// MARK: - everyNHours

@Test func everyNHoursFiresOnHourMultiplesWithinWindow() {
    let dates = GroupPlanner.plan(
        group: group(schedule: .everyNHours(3)),
        awakeStart: date(2026, 7, 8, 8), awakeEnd: date(2026, 7, 9, 0),
        seed: 1, calendar: calendar)
    // 8:00 wake → 11:00, 14:00, 17:00, 20:00, 23:00 (midnight excluded).
    #expect(dates == [date(2026, 7, 8, 11), date(2026, 7, 8, 14), date(2026, 7, 8, 17),
                      date(2026, 7, 8, 20), date(2026, 7, 8, 23)])
}

@Test func everyNHoursCrossesMidnight() {
    // Awake 22:00 → 06:00 next day, every 2 hours.
    let dates = GroupPlanner.plan(
        group: group(schedule: .everyNHours(2)),
        awakeStart: date(2026, 7, 8, 22), awakeEnd: date(2026, 7, 9, 6),
        seed: 1, calendar: calendar)
    #expect(dates == [date(2026, 7, 9, 0), date(2026, 7, 9, 2), date(2026, 7, 9, 4)])
}

// MARK: - timesPerDay

@Test func timesPerDayIsDeterministicAndInWindow() {
    let g = group(schedule: .timesPerDay(count: 4, distribution: .semiRandom))
    let start = date(2026, 7, 8, 8), end = date(2026, 7, 9, 0)
    let first = GroupPlanner.plan(group: g, awakeStart: start, awakeEnd: end, seed: 42, calendar: calendar)
    let second = GroupPlanner.plan(group: g, awakeStart: start, awakeEnd: end, seed: 42, calendar: calendar)
    #expect(first == second)
    #expect(first.count == 4)
    #expect(first.allSatisfy { $0 >= start && $0 < end })
    #expect(first == first.sorted())
}

@Test func timesPerDaySeedVariesByGroupID() {
    let a = group(schedule: .timesPerDay(count: 4, distribution: .random), id: "pg-a")
    let b = group(schedule: .timesPerDay(count: 4, distribution: .random), id: "pg-b")
    let start = date(2026, 7, 8, 8), end = date(2026, 7, 9, 0)
    let datesA = GroupPlanner.plan(group: a, awakeStart: start, awakeEnd: end, seed: 42, calendar: calendar)
    let datesB = GroupPlanner.plan(group: b, awakeStart: start, awakeEnd: end, seed: 42, calendar: calendar)
    #expect(datesA != datesB)
}

// MARK: - dailyAt

@Test func dailyAtMaterializesTimesWithinWindowOnly() {
    var nine = DateComponents(); nine.hour = 9; nine.minute = 15
    var six = DateComponents(); six.hour = 6 // before awakeStart → dropped
    let dates = GroupPlanner.plan(
        group: group(schedule: .dailyAt([nine, six])),
        awakeStart: date(2026, 7, 8, 8), awakeEnd: date(2026, 7, 9, 0),
        seed: 1, calendar: calendar)
    #expect(dates == [date(2026, 7, 8, 9, 15)])
}

@Test func dailyAtRollsToNextDayForMidnightCrossingWindow() {
    // Awake 22:00 → 06:00; a 02:00 scheduled time falls on the NEXT calendar day.
    var two = DateComponents(); two.hour = 2
    let dates = GroupPlanner.plan(
        group: group(schedule: .dailyAt([two])),
        awakeStart: date(2026, 7, 8, 22), awakeEnd: date(2026, 7, 9, 6),
        seed: 1, calendar: calendar)
    #expect(dates == [date(2026, 7, 9, 2)])
}

// MARK: - event / degenerate

@Test func eventAndDisabledSchedulesAreNeverTimerPlanned() {
    let start = date(2026, 7, 8, 8), end = date(2026, 7, 9, 0)
    #expect(GroupPlanner.plan(group: group(schedule: .workoutEnd),
                              awakeStart: start, awakeEnd: end, seed: 1, calendar: calendar).isEmpty)
    let unknown = PromptGroup()
    unknown.scheduleKindRaw = "someFutureKind"
    #expect(GroupPlanner.plan(group: unknown,
                              awakeStart: start, awakeEnd: end, seed: 1, calendar: calendar).isEmpty)
}

@Test func emptyOrInvertedWindowPlansNothing() {
    let g = group(schedule: .everyNHours(1))
    #expect(GroupPlanner.plan(group: g, awakeStart: date(2026, 7, 8, 8),
                              awakeEnd: date(2026, 7, 8, 8), seed: 1, calendar: calendar).isEmpty)
    #expect(GroupPlanner.plan(group: g, awakeStart: date(2026, 7, 8, 8),
                              awakeEnd: date(2026, 7, 8, 6), seed: 1, calendar: calendar).isEmpty)
}

@Test func stableHashIsStableAcrossCalls() {
    #expect(GroupPlanner.stableHash("pg-a") == GroupPlanner.stableHash("pg-a"))
    #expect(GroupPlanner.stableHash("pg-a") != GroupPlanner.stableHash("pg-b"))
}
