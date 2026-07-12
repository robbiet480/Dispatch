import Foundation
import Testing
@testable import DispatchKit

/// Plan 51: the "Random check-ins" toggle. Two contracts are pinned here — the
/// migration-safe default of `NotificationPrefs.randomCheckInsEnabled`, and the
/// scheduler's global gate (`PromptPlanner.globalPlan`, the single source of
/// truth `NotificationScheduler.plannedDates` routes every plan window through):
/// with the toggle OFF the app plans ZERO random global prompts while prompt
/// groups (planned by the separate `GroupPlanner` path) still fire.

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "np-randomcheckins-\(UUID().uuidString)")!
}

private let calendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "GMT")!
    return cal
}()

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private let windowStart = date(2026, 7, 8, 8)
private let windowEnd = date(2026, 7, 9, 0) // 16h awake window

private func prefs(alertsPerDay: Int = 4,
                   distribution: PromptDistribution = .semiRandom,
                   scheduledTimes: [DateComponents] = []) -> NotificationPrefs {
    let p = NotificationPrefs(defaults: freshDefaults())
    p.alertsPerDay = alertsPerDay
    p.distribution = distribution
    p.scheduledTimes = scheduledTimes
    return p
}

// MARK: - Migration-safe default (the load-bearing existing-user safety)

@Test func randomCheckInsDefaultsToTrueWhenKeyAbsent() {
    // An existing user upgrading has NEVER written this key. A naive
    // `defaults.bool(forKey:)` would return false and silently kill their
    // randoms — the default MUST read true.
    let defaults = freshDefaults()
    #expect(defaults.object(forKey: "randomCheckInsEnabled") == nil)
    #expect(NotificationPrefs(defaults: defaults).randomCheckInsEnabled == true)
}

@Test func randomCheckInsPersistsExplicitFalse() {
    let defaults = freshDefaults()
    NotificationPrefs(defaults: defaults).randomCheckInsEnabled = false
    // A NEW prefs instance over the same suite must read the stored false —
    // only an explicit off disables the randoms.
    #expect(NotificationPrefs(defaults: defaults).randomCheckInsEnabled == false)
}

@Test func randomCheckInsPersistsExplicitTrue() {
    let defaults = freshDefaults()
    let p = NotificationPrefs(defaults: defaults)
    p.randomCheckInsEnabled = false
    p.randomCheckInsEnabled = true
    #expect(NotificationPrefs(defaults: defaults).randomCheckInsEnabled == true)
}

// MARK: - The gate: OFF plans zero random global prompts

@Test func globalPlanOffPlansNoRandomPrompts() {
    let dates = PromptPlanner.globalPlan(
        randomCheckInsEnabled: false, prefs: prefs(alertsPerDay: 4),
        awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    #expect(dates.isEmpty)
}

@Test func globalPlanOffKeepsExplicitScheduledTimes() {
    // The gate targets the RANDOM schedule only: an explicit fixed time still
    // materializes even with randoms off (zero random prompts, one scheduled).
    var nine = DateComponents(); nine.hour = 9; nine.minute = 15
    let dates = PromptPlanner.globalPlan(
        randomCheckInsEnabled: false, prefs: prefs(alertsPerDay: 4, scheduledTimes: [nine]),
        awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    #expect(dates == [date(2026, 7, 8, 9, 15)])
}

// MARK: - The gate: ON is unchanged behavior

@Test func globalPlanOnPlansTheFullRandomSchedule() {
    let p = prefs(alertsPerDay: 4, distribution: .semiRandom)
    let onDates = PromptPlanner.globalPlan(
        randomCheckInsEnabled: true, prefs: p,
        awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    // Exact count, and byte-identical to the ungated `plan(prefs:)` the
    // scheduler used before the toggle existed.
    #expect(onDates.count == 4)
    let legacy = PromptPlanner.plan(
        prefs: p, awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    #expect(onDates == legacy)
}

// MARK: - Groups still fire regardless of the toggle

@Test func promptGroupsPlanIndependentlyOfTheRandomToggle() {
    let g = PromptGroup()
    g.uniqueIdentifier = "pg-timer"
    g.schedule = .timesPerDay(count: 3, distribution: .semiRandom)

    // Groups don't consult randomCheckInsEnabled at all — same plan whether the
    // global toggle is on or off.
    let groupDates = GroupPlanner.plan(
        group: g, awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    #expect(groupDates.count == 3)
    #expect(groupDates.allSatisfy { $0 >= windowStart && $0 < windowEnd })

    // The scheduler's decision in miniature: random OFF ⇒ zero global, groups
    // still planned. This is the "rely on Prompt Groups only" contract.
    let globalOff = PromptPlanner.globalPlan(
        randomCheckInsEnabled: false, prefs: prefs(alertsPerDay: 4),
        awakeStart: windowStart, awakeEnd: windowEnd, seed: 42, calendar: calendar)
    #expect(globalOff.isEmpty)
    #expect(!groupDates.isEmpty)
}
