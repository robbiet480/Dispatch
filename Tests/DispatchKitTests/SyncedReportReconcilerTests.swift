import Foundation
import Testing
@testable import DispatchKit

// Plan 19: phone-side nag reconciliation on remote report arrival — the
// three guards, each with its own fixture.

private let now = Date(timeIntervalSince1970: 1_780_000_000)
/// A representative nag-chain lifetime: 10min delay + 5 nags × 15min.
private let window: TimeInterval = (10 + 5 * 15) * 60

@Test func freshRemoteReportAdvancesTheFloorFromItsOwnTimestamp() {
    let reportDate = now.addingTimeInterval(-5 * 60)
    let floor = SyncedReportReconciler.newFloor(
        reportDates: [reportDate],
        currentFloor: now.addingTimeInterval(-60 * 60),
        now: now, window: window
    )
    // Report-timestamp basis: the floor is the report's date, NOT `now`
    // (the arrival time).
    #expect(floor == reportDate)
}

@Test func newestQualifyingReportWins() {
    let older = now.addingTimeInterval(-20 * 60)
    let newer = now.addingTimeInterval(-3 * 60)
    let floor = SyncedReportReconciler.newFloor(
        reportDates: [older, newer], currentFloor: nil, now: now, window: window
    )
    #expect(floor == newer)
}

@Test func olderThanCurrentFloorNeverRegresses() {
    let current = now.addingTimeInterval(-2 * 60)
    let floor = SyncedReportReconciler.newFloor(
        reportDates: [now.addingTimeInterval(-10 * 60)],
        currentFloor: current,
        now: now, window: window
    )
    // Forward-only: a report older than the existing floor changes nothing.
    #expect(floor == nil)
}

@Test func historicalBackfillOutsideTheNagWindowIsIgnored() {
    // Initial-sync backfill / import / dedupe churn: reports from days ago
    // must not floor a live nag chain.
    let historical = now.addingTimeInterval(-3 * 24 * 60 * 60)
    let floor = SyncedReportReconciler.newFloor(
        reportDates: [historical], currentFloor: nil, now: now, window: window
    )
    #expect(floor == nil)
}

@Test func futureDatedReportFromClockSkewIsIgnored() {
    let floor = SyncedReportReconciler.newFloor(
        reportDates: [now.addingTimeInterval(5 * 60)],
        currentFloor: nil, now: now, window: window
    )
    #expect(floor == nil)
}

@Test func mixedArrivalsApplyAllGuardsTogether() {
    let current = now.addingTimeInterval(-30 * 60)
    let qualifying = now.addingTimeInterval(-8 * 60)
    let dates = [
        now.addingTimeInterval(-3 * 24 * 60 * 60), // historical → ignored
        now.addingTimeInterval(-45 * 60),          // older than floor → ignored
        qualifying,                                 // fresh → wins
        now.addingTimeInterval(10 * 60),            // future skew → ignored
    ]
    let floor = SyncedReportReconciler.newFloor(
        reportDates: dates, currentFloor: current, now: now, window: window
    )
    #expect(floor == qualifying)
}

@Test func emptyArrivalsDoNothing() {
    #expect(SyncedReportReconciler.newFloor(
        reportDates: [], currentFloor: nil, now: now, window: window
    ) == nil)
}
