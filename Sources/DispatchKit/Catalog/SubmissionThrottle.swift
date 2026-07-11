import Foundation

/// Per-device catalog submission throttle (plan 38): at most
/// `dailyLimit` submissions per rolling 24-hour window.
///
/// **This is friction, not security.** The counter lives in the device's own
/// `UserDefaults`; anyone scripting CloudKit Web Services directly — or just
/// deleting the app — bypasses it trivially, and CloudKit's public database
/// offers no server-side rate limiting for authenticated creates. Its job is
/// to stop honest users from accidental double-submits and make casual abuse
/// boring. The actual abuse control is moderation-side: `dispatch-mod`'s
/// flood detection and `reject-user` bulk cleanup — nothing reaches the
/// catalog without approval.
///
/// Pure value logic with an injected clock (`now:` parameters, never
/// `Date()` inside), so every path is unit-testable without waiting 24 hours.
public struct SubmissionThrottle: Equatable, Sendable {
    /// Submissions allowed per device per rolling window. Generous for a
    /// human, irrelevant to a script (see the type doc comment).
    public static let dailyLimit = 5

    /// Rolling window length. A timestamp exactly `window` old has expired
    /// (strictly-less-than comparison).
    public static let window: TimeInterval = 24 * 60 * 60

    /// Raw submission timestamps, unpruned and in any order. Callers persist
    /// this array; pruning happens on read and on `recording(now:)`.
    public var timestamps: [Date]

    public init(timestamps: [Date] = []) {
        self.timestamps = timestamps
    }

    /// Timestamps still inside the rolling window, oldest first.
    public func active(now: Date) -> [Date] {
        timestamps.filter { now.timeIntervalSince($0) < Self.window }.sorted()
    }

    public func remaining(now: Date) -> Int {
        max(0, Self.dailyLimit - active(now: now).count)
    }

    public func canSubmit(now: Date) -> Bool {
        remaining(now: now) > 0
    }

    /// The throttle after a SUCCESSFUL submission: stale entries pruned,
    /// `now` appended. Callers must only invoke this when the provider's
    /// submit returned without throwing — a failed submit never burns a slot.
    public func recording(now: Date) -> SubmissionThrottle {
        SubmissionThrottle(timestamps: active(now: now) + [now])
    }

    /// When the next slot frees up (oldest active entry + window), or nil
    /// while submissions are still allowed. Drives the "try again after" UI.
    public func nextAllowed(now: Date) -> Date? {
        guard !canSubmit(now: now), let oldest = active(now: now).first else { return nil }
        return oldest.addingTimeInterval(Self.window)
    }
}
