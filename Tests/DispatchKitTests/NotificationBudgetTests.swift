import Foundation
import Testing
@testable import DispatchKit

private let nags = NotificationBudget.NagRequest(delayMinutes: 10, intervalMinutes: 5, maxCount: 3)

@Test func allocatorGrantsEverythingUnderCap() {
    let allocation = NotificationBudget.allocate(
        globalCount: 8,
        groupCounts: [("a", 4), ("b", 2)],
        nagRequest: nags,
        cap: 64)
    #expect(allocation.global == 8)
    #expect(allocation.count(forGroup: "a") == 4)
    #expect(allocation.count(forGroup: "b") == 2)
    #expect(allocation.nagsPerPrompt == 3) // 50 remaining / 14 prompts ≥ 3
    #expect(allocation.total <= 64)
}

@Test func overflowTrimsGroupsInOrderAfterGlobal() {
    // Global eats 60 of 64; group "a" gets the last 4, "b" gets nothing.
    let allocation = NotificationBudget.allocate(
        globalCount: 60,
        groupCounts: [("a", 10), ("b", 10)],
        nagRequest: nil,
        cap: 64)
    #expect(allocation.global == 60)
    #expect(allocation.count(forGroup: "a") == 4)
    #expect(allocation.count(forGroup: "b") == 0)
    #expect(allocation.total == 64)
}

@Test func globalItselfIsCappedAtBudget() {
    let allocation = NotificationBudget.allocate(
        globalCount: 100, groupCounts: [("a", 5)], nagRequest: nags, cap: 64)
    #expect(allocation.global == 64)
    #expect(allocation.count(forGroup: "a") == 0)
    #expect(allocation.nagsPerPrompt == 0)
    #expect(allocation.total == 64)
}

@Test func nagsGetOnlyTheLeftovers() {
    // 20 prompts of 64 → 44 remaining → 44/20 = 2 nags/prompt (maxCount 3 clamped).
    let allocation = NotificationBudget.allocate(
        globalCount: 12, groupCounts: [("a", 8)], nagRequest: nags, cap: 64)
    #expect(allocation.nagsPerPrompt == 2)
    #expect(allocation.total == 60)
    #expect(allocation.total <= 64)
}

@Test func nagClampMatchesLegacyNagPlannerMath() {
    // Existing behavior (plan 10): budget 60, prompts only from the global
    // schedule → effectiveCount = min(maxCount, (60 - n) / n).
    for promptCount in [1, 4, 12, 30] {
        let allocation = NotificationBudget.allocate(
            globalCount: promptCount, groupCounts: [], nagRequest: nags, cap: 60)
        let legacy = max(0, min(nags.maxCount, (60 - promptCount) / promptCount))
        #expect(allocation.nagsPerPrompt == legacy)
    }
}

@Test func zeroCases() {
    let empty = NotificationBudget.allocate(
        globalCount: 0, groupCounts: [], nagRequest: nags, cap: 64)
    #expect(empty.global == 0)
    #expect(empty.nagsPerPrompt == 0) // no prompts → no nags, no division by zero
    #expect(empty.total == 0)

    let zeroCap = NotificationBudget.allocate(
        globalCount: 5, groupCounts: [("a", 5)], nagRequest: nags, cap: 0)
    #expect(zeroCap.total == 0)

    let negative = NotificationBudget.allocate(
        globalCount: -3, groupCounts: [("a", -1)], nagRequest: nags, cap: 64)
    #expect(negative.global == 0)
    #expect(negative.count(forGroup: "a") == 0)
}

@Test func resurrectedPastParentTailsAreChargedAgainstTheCap() {
    // 20 future prompts + resurrected tails for 10 past parents. Each past
    // parent fired 1 minute ago; delay 10m / interval 5m means EVERY fire of
    // its chain is still in the future, so a chain of length n adds n tails
    // per past parent. Without charging tails: nags = min(3, 40/20) = 2 and
    // total adds = 20*3 + 10*2 = 80 > 60. With charging: n=2 needs
    // 20*2 + 10*2 = 60 > 40, n=1 needs 20 + 10 = 30 ≤ 40 → nags clamp to 1.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let pastParents = (0..<10).map { _ in now.addingTimeInterval(-60) }
    let allocation = NotificationBudget.allocate(
        globalCount: 12,
        groupCounts: [("a", 8)],
        nagRequest: nags,
        pastNagParents: pastParents,
        now: now,
        cap: 60)
    #expect(allocation.nagsPerPrompt == 1)
    #expect(allocation.pastNagTails == 10)
    #expect(allocation.total == 20 * 2 + 10)
    #expect(allocation.total <= 60)
}

@Test func onlyStillFutureTailFiresAreCharged() {
    // A past parent whose chain has partially elapsed: fired 16 minutes ago
    // with delay 10m / interval 5m → fires at -6m, -1m, +4m. Only the +4m
    // fire is still pending, so exactly 1 tail is charged and the full
    // maxCount chain length survives.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let allocation = NotificationBudget.allocate(
        globalCount: 4,
        groupCounts: [],
        nagRequest: nags,
        pastNagParents: [now.addingTimeInterval(-16 * 60)],
        now: now,
        cap: 64)
    #expect(allocation.nagsPerPrompt == 3)
    #expect(allocation.pastNagTails == 1)
    #expect(allocation.total == 4 * 4 + 1)
}

@Test func noPastParentsMatchesLegacyAllocation() {
    // The default (no past parents) must be byte-for-byte the old arithmetic.
    let allocation = NotificationBudget.allocate(
        globalCount: 12, groupCounts: [("a", 8)], nagRequest: nags, cap: 64)
    #expect(allocation.nagsPerPrompt == 2)
    #expect(allocation.pastNagTails == 0)
    #expect(allocation.total == 60)
}

@Test func nilNagRequestMeansZeroNags() {
    let allocation = NotificationBudget.allocate(
        globalCount: 4, groupCounts: [("a", 2)], nagRequest: nil, cap: 64)
    #expect(allocation.nagsPerPrompt == 0)
    #expect(allocation.total == 6)
}
