import Foundation
import Testing
@testable import DispatchKit

private func freshPrefs() -> NotificationPrefs {
    NotificationPrefs(defaults: UserDefaults(suiteName: "nag-\(UUID().uuidString)")!)
}

private let base = ISO8601DateFormatter().date(from: "2026-07-08T10:00:00Z")!

// MARK: - Chain math

@Test func chainFiresAtDelayThenIntervalSpacing() {
    let plans = NagPlanner.plan(promptDates: [base], delayMinutes: 10, intervalMinutes: 5, maxCount: 3, budget: 60)
    #expect(plans.count == 1)
    #expect(plans[0].parent == base)
    #expect(plans[0].fires == [
        base.addingTimeInterval(10 * 60),
        base.addingTimeInterval(15 * 60),
        base.addingTimeInterval(20 * 60),
    ])
}

@Test func everyParentGetsItsOwnChain() {
    let second = base.addingTimeInterval(3600)
    let plans = NagPlanner.plan(promptDates: [base, second], delayMinutes: 1, intervalMinutes: 1, maxCount: 2, budget: 60)
    #expect(plans.count == 2)
    #expect(plans[0].parent == base)
    #expect(plans[1].parent == second)
    #expect(plans[1].fires == [
        second.addingTimeInterval(60),
        second.addingTimeInterval(120),
    ])
}

// MARK: - Budget clamping

@Test func budgetClampsCountAt12PerDayTimes2() {
    // 24 prompts (12/day x 2 days), budget 60: (60 - 24) / 24 = 1 nag each.
    let prompts = (0..<24).map { base.addingTimeInterval(TimeInterval($0) * 3600) }
    let plans = NagPlanner.plan(promptDates: prompts, delayMinutes: 10, intervalMinutes: 5, maxCount: 3, budget: 60)
    #expect(plans.count == 24)
    #expect(plans.allSatisfy { $0.fires.count == 1 })
}

@Test func budgetClampToZeroYieldsEmptyFires() {
    // 40 prompts, budget 60: (60 - 40) / 40 = 0 nags.
    let prompts = (0..<40).map { base.addingTimeInterval(TimeInterval($0) * 60) }
    let plans = NagPlanner.plan(promptDates: prompts, delayMinutes: 10, intervalMinutes: 5, maxCount: 3, budget: 60)
    #expect(plans.count == 40)
    #expect(plans.allSatisfy { $0.fires.isEmpty })
}

@Test func negativeBudgetHeadroomFloorsAtZero() {
    let prompts = (0..<10).map { base.addingTimeInterval(TimeInterval($0) * 60) }
    let plans = NagPlanner.plan(promptDates: prompts, delayMinutes: 5, intervalMinutes: 5, maxCount: 5, budget: 4)
    #expect(plans.allSatisfy { $0.fires.isEmpty })
}

@Test func maxCountZeroYieldsEmptyFires() {
    let plans = NagPlanner.plan(promptDates: [base], delayMinutes: 10, intervalMinutes: 5, maxCount: 0, budget: 60)
    #expect(plans.count == 1)
    #expect(plans[0].fires.isEmpty)
}

@Test func zeroPromptInputYieldsEmptyPlan() {
    let plans = NagPlanner.plan(promptDates: [], delayMinutes: 10, intervalMinutes: 5, maxCount: 3, budget: 60)
    #expect(plans.isEmpty)
}

@Test func defaultsAtFourPerDayFitBudgetUnclamped() {
    // 8 prompts (4/day x 2 days), 3 nags each: (60 - 8) / 8 = 6 >= 3 — unclamped.
    let prompts = (0..<8).map { base.addingTimeInterval(TimeInterval($0) * 3600) }
    let plans = NagPlanner.plan(promptDates: prompts, delayMinutes: 10, intervalMinutes: 5, maxCount: 3, budget: 60)
    #expect(plans.allSatisfy { $0.fires.count == 3 })
}

// MARK: - Prefs defaults + clamping

@Test func nagPrefsDefaults() {
    let p = freshPrefs()
    #expect(p.nagEnabled == false)
    #expect(p.nagDelayMinutes == 10)
    #expect(p.nagIntervalMinutes == 5)
    #expect(p.nagMaxCount == 3)
}

@Test func nagPrefsRoundTrip() {
    let p = freshPrefs()
    p.nagEnabled = true
    p.nagDelayMinutes = 30
    p.nagIntervalMinutes = 7
    p.nagMaxCount = 5
    #expect(p.nagEnabled == true)
    #expect(p.nagDelayMinutes == 30)
    #expect(p.nagIntervalMinutes == 7)
    #expect(p.nagMaxCount == 5)
}

@Test func nagPrefsClampBounds() {
    let p = freshPrefs()
    p.nagDelayMinutes = 500
    #expect(p.nagDelayMinutes == 120)
    p.nagDelayMinutes = -3
    #expect(p.nagDelayMinutes == 1)
    p.nagIntervalMinutes = 90
    #expect(p.nagIntervalMinutes == 60)
    p.nagIntervalMinutes = 0
    #expect(p.nagIntervalMinutes == 1)
    p.nagMaxCount = 99
    #expect(p.nagMaxCount == 10)
    p.nagMaxCount = -1
    #expect(p.nagMaxCount == 1)
}
