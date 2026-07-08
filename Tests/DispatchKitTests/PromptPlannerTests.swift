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

@Test func distributionDescriptions() {
    #expect(PromptDistribution.random.description(alertsPerDay: 6) == "6 randomly timed alerts every 24 hours")
    #expect(PromptDistribution.semiRandom.description(alertsPerDay: 6) == "1 random alert every 4 hours")
    #expect(PromptDistribution.regular.description(alertsPerDay: 6) == "1 alert every 4 hours")
}
