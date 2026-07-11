import Foundation
import Testing

@testable import DispatchKit

/// Plan 38: per-device catalog submission throttle. Pure value logic over an
/// injected clock — no `Date()` anywhere inside the type.
struct SubmissionThrottleTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func emptyHistoryAllowsFullQuota() {
        let throttle = SubmissionThrottle(timestamps: [])
        #expect(throttle.remaining(now: now) == SubmissionThrottle.dailyLimit)
        #expect(throttle.canSubmit(now: now))
        #expect(throttle.nextAllowed(now: now) == nil)
    }

    @Test func recordingConsumesOneSlot() {
        var throttle = SubmissionThrottle(timestamps: [])
        throttle = throttle.recording(now: now)
        #expect(throttle.remaining(now: now) == SubmissionThrottle.dailyLimit - 1)
        #expect(throttle.canSubmit(now: now))
    }

    @Test func limitReachedBlocksSubmission() {
        let recent = (0..<SubmissionThrottle.dailyLimit).map { now.addingTimeInterval(-Double($0) * 60) }
        let throttle = SubmissionThrottle(timestamps: recent)
        #expect(throttle.remaining(now: now) == 0)
        #expect(!throttle.canSubmit(now: now))
    }

    @Test func timestampExactly24HoursOldHasExpired() {
        // Strictly-less-than window: a slot burned exactly 24h ago is free again.
        let boundary = now.addingTimeInterval(-SubmissionThrottle.window)
        let throttle = SubmissionThrottle(timestamps: [boundary])
        #expect(throttle.remaining(now: now) == SubmissionThrottle.dailyLimit)
        #expect(throttle.canSubmit(now: now))
    }

    @Test func timestampJustInsideWindowStillCounts() {
        let inside = now.addingTimeInterval(-SubmissionThrottle.window + 1)
        let throttle = SubmissionThrottle(timestamps: [inside])
        #expect(throttle.remaining(now: now) == SubmissionThrottle.dailyLimit - 1)
    }

    @Test func recordingPrunesStaleEntries() {
        let stale = (1...20).map { now.addingTimeInterval(-SubmissionThrottle.window - Double($0)) }
        let throttle = SubmissionThrottle(timestamps: stale).recording(now: now)
        #expect(throttle.timestamps == [now])
    }

    @Test func orderingInsensitiveInput() {
        let scrambled = [
            now.addingTimeInterval(-100),
            now.addingTimeInterval(-90_000), // stale
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-3_600),
        ]
        let throttle = SubmissionThrottle(timestamps: scrambled)
        #expect(throttle.remaining(now: now) == SubmissionThrottle.dailyLimit - 3)
        // nextAllowed keys off the OLDEST active entry regardless of order.
        let exhausted = SubmissionThrottle(
            timestamps: scrambled + [now.addingTimeInterval(-50), now.addingTimeInterval(-20_000)]
        )
        #expect(exhausted.remaining(now: now) == 0)
        #expect(exhausted.nextAllowed(now: now)
            == now.addingTimeInterval(-20_000).addingTimeInterval(SubmissionThrottle.window))
    }

    @Test func nextAllowedNilWhileSlotsRemain() {
        let throttle = SubmissionThrottle(timestamps: [now.addingTimeInterval(-60)])
        #expect(throttle.nextAllowed(now: now) == nil)
    }

    @Test func nextAllowedIsOldestActivePlusWindow() {
        let oldest = now.addingTimeInterval(-23 * 3_600)
        var timestamps = [oldest]
        timestamps += (0..<(SubmissionThrottle.dailyLimit - 1)).map { now.addingTimeInterval(-Double($0 + 1) * 60) }
        let throttle = SubmissionThrottle(timestamps: timestamps)
        #expect(!throttle.canSubmit(now: now))
        #expect(throttle.nextAllowed(now: now) == oldest.addingTimeInterval(SubmissionThrottle.window))
    }
}
