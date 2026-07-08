import Foundation
import Testing
@testable import DispatchKit

private func prefs(_ n: Int, _ d: PromptDistribution, times: [DateComponents] = []) -> NotificationPrefs {
    let p = NotificationPrefs(defaults: UserDefaults(suiteName: "np-\(UUID().uuidString)")!)
    p.alertsPerDay = n
    p.distribution = d
    p.scheduledTimes = times
    return p
}

private let dayStart = ISO8601DateFormatter().date(from: "2026-07-08T08:00:00Z")!
private let dayEnd = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")! // 16h window

@Test func planIsDeterministicForSameSeed() {
    let p = prefs(6, .random)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let a = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 42, calendar: calendar)
    let b = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 42, calendar: calendar)
    let c = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 43, calendar: calendar)
    #expect(a == b)
    #expect(a != c)
}

@Test func randomProducesSortedTimesInsideWindow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = PromptPlanner.plan(prefs: prefs(6, .random), awakeStart: dayStart, awakeEnd: dayEnd, seed: 7, calendar: calendar)
    #expect(dates.count == 6)
    #expect(dates == dates.sorted())
    #expect(dates.allSatisfy { $0 >= dayStart && $0 < dayEnd })
}

@Test func semiRandomPutsOneAlertPerSlot() {
    let n = 4
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = PromptPlanner.plan(prefs: prefs(n, .semiRandom), awakeStart: dayStart, awakeEnd: dayEnd, seed: 9, calendar: calendar)
    #expect(dates.count == n)
    let slot = dayEnd.timeIntervalSince(dayStart) / Double(n)
    for (index, date) in dates.enumerated() {
        let offset = date.timeIntervalSince(dayStart)
        #expect(offset >= slot * Double(index) && offset < slot * Double(index + 1))
    }
}

@Test func regularIsEvenlySpaced() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = PromptPlanner.plan(prefs: prefs(4, .regular), awakeStart: dayStart, awakeEnd: dayEnd, seed: 1, calendar: calendar)
    #expect(dates.count == 4)
    let interval = dayEnd.timeIntervalSince(dayStart) / 4
    for (index, date) in dates.enumerated() {
        #expect(abs(date.timeIntervalSince(dayStart) - interval * Double(index)) < 1)
    }
}

@Test func scheduledTimesAppendAndDedupe() {
    var nine = DateComponents(); nine.hour = 9; nine.minute = 30
    let p = prefs(2, .regular, times: [nine])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 1, calendar: calendar)
    #expect(dates.count == 3)
    #expect(dates.contains { calendar.component(.hour, from: $0) == 9 && calendar.component(.minute, from: $0) == 30 })
}

@Test func scheduledTimeCrossingMidnightMaterializesOnCorrectDay() {
    // Use a scheduled time (02:17) that a 1-alert .random distribution over an
    // 8-hour window is vanishingly unlikely to land on by chance, so the only way
    // dates can contain 02:17 is via the scheduledTimes materialization path.
    var twoSeventeenAM = DateComponents(); twoSeventeenAM.hour = 2; twoSeventeenAM.minute = 17
    let p = prefs(1, .random, times: [twoSeventeenAM])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let awakeStart = ISO8601DateFormatter().date(from: "2026-07-08T22:00:00Z")!
    let awakeEnd = ISO8601DateFormatter().date(from: "2026-07-09T06:00:00Z")!
    let dates = PromptPlanner.plan(prefs: p, awakeStart: awakeStart, awakeEnd: awakeEnd, seed: 1, calendar: calendar)
    let expectedTwoSeventeenAM = ISO8601DateFormatter().date(from: "2026-07-09T02:17:00Z")!
    #expect(dates.contains(expectedTwoSeventeenAM))
    #expect(dates.allSatisfy { $0 >= awakeStart && $0 < awakeEnd })
}

@Test func scheduledTimesPersistAcrossNewInstanceOnSameSuite() {
    let suiteName = "np-persist-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    var nine = DateComponents(); nine.hour = 9; nine.minute = 15
    let first = NotificationPrefs(defaults: defaults)
    first.scheduledTimes = [nine]

    let second = NotificationPrefs(defaults: defaults)
    #expect(second.scheduledTimes.count == 1)
    #expect(second.scheduledTimes.first?.hour == 9)
    #expect(second.scheduledTimes.first?.minute == 15)
}

@Test func alertsPerDayOneYieldsSingleInWindowDateForEachDistribution() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for distribution in [PromptDistribution.random, .semiRandom, .regular] {
        let dates = PromptPlanner.plan(prefs: prefs(1, distribution), awakeStart: dayStart, awakeEnd: dayEnd, seed: 3, calendar: calendar)
        #expect(dates.count == 1)
        #expect(dates.allSatisfy { $0 >= dayStart && $0 < dayEnd })
    }
}

@Test func shortWindowStillYieldsAllSortedInWindowDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let shortStart = dayStart
    let shortEnd = dayStart.addingTimeInterval(10 * 60) // 10 minute window
    let n = 4
    let dates = PromptPlanner.plan(prefs: prefs(n, .regular), awakeStart: shortStart, awakeEnd: shortEnd, seed: 5, calendar: calendar)
    #expect(dates.count == n)
    #expect(dates == dates.sorted())
    #expect(dates.allSatisfy { $0 >= shortStart && $0 < shortEnd })
}

@Test func scheduledTimeCollidingWithRegularDistributionDedupes() {
    // awakeStart is 08:00, so a .regular distribution with N alerts always includes
    // a date exactly at awakeStart (offset 0). Schedule a time matching that same
    // hour/minute to force a deliberate collision.
    var eightAM = DateComponents(); eightAM.hour = 8; eightAM.minute = 0
    let p = prefs(4, .regular, times: [eightAM])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dates = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 1, calendar: calendar)
    #expect(dates.count == 4) // not 5 - the scheduled time deduped against the regular date at awakeStart
    let matches = dates.filter { calendar.component(.hour, from: $0) == 8 && calendar.component(.minute, from: $0) == 0 }
    #expect(matches.count == 1)
}

@Test func prefsClampAndPersist() {
    let defaults = UserDefaults(suiteName: "np-clamp-\(UUID().uuidString)")!
    let p = NotificationPrefs(defaults: defaults)
    #expect(p.alertsPerDay == 4)
    #expect(p.distribution == .semiRandom)
    p.alertsPerDay = 99
    #expect(p.alertsPerDay == 12)
    p.alertsPerDay = 0
    #expect(p.alertsPerDay == 1)
    p.distribution = .random
    #expect(NotificationPrefs(defaults: defaults).distribution == .random)
}

@Test func lastActedAtDefaultsNilAndRoundTrips() {
    let defaults = UserDefaults(suiteName: "np-acted-\(UUID().uuidString)")!
    let p = NotificationPrefs(defaults: defaults)
    #expect(p.lastActedAt == nil)

    let acted = Date(timeIntervalSince1970: 1_750_000_000)
    p.lastActedAt = acted
    #expect(p.lastActedAt == acted)
    // Persists across instances over the same defaults suite.
    #expect(NotificationPrefs(defaults: defaults).lastActedAt == acted)

    p.lastActedAt = nil
    #expect(p.lastActedAt == nil)
    // Zero/unset sentinel reads back as nil, not the epoch.
    defaults.set(0.0, forKey: "lastActedAt")
    #expect(p.lastActedAt == nil)
}

@Test func distributionDescriptions() {
    #expect(PromptDistribution.random.description(alertsPerDay: 6) == "6 randomly timed alerts every 24 hours")
    #expect(PromptDistribution.semiRandom.description(alertsPerDay: 6) == "1 random alert every 4 hours")
    #expect(PromptDistribution.regular.description(alertsPerDay: 6) == "1 alert every 4 hours")
}
