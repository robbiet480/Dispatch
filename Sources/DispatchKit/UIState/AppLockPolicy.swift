import Foundation

/// Pure decision logic for whether returning to the foreground should
/// re-lock the app. Extracted from `AppLockStore.evaluateReturnFromBackground`
/// so the grace-period math is independently testable without constructing
/// a full `AppLockStore` or waiting on real wall-clock time.
public enum AppLockPolicy {
    /// - Parameters:
    ///   - enabled: Whether app lock is turned on in settings.
    ///   - backgroundedAt: When the app was backgrounded, or `nil` if it never was.
    ///   - now: The current time to evaluate against.
    ///   - graceSeconds: How long the app may stay backgrounded before re-locking.
    ///     Elapsed time exactly equal to this value does NOT lock — only
    ///     strictly-greater-than-grace elapsed time locks, matching the
    ///     original `> backgroundGraceInterval` semantics.
    /// - Returns: `true` if the app should re-lock.
    public static func shouldLock(
        enabled: Bool,
        backgroundedAt: Date?,
        now: Date,
        graceSeconds: TimeInterval = 60
    ) -> Bool {
        guard enabled, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) > graceSeconds
    }

    /// Whether report content may be indexed into system-wide Spotlight.
    ///
    /// Policy: while app lock is enabled, indexing is off by default — Spotlight
    /// results could reveal report content without unlocking the app. The user
    /// can explicitly opt back in via the "Spotlight Search While Locked"
    /// setting, accepting that trade-off. When app lock is off the opt-in flag
    /// is irrelevant: indexing is always allowed.
    ///
    /// - Parameters:
    ///   - lockEnabled: Whether app lock is turned on in settings.
    ///   - spotlightWhileLockedEnabled: The "Spotlight Search While Locked" opt-in.
    /// - Returns: `true` if Spotlight indexing is allowed.
    public static func allowsSpotlightIndexing(
        lockEnabled: Bool,
        spotlightWhileLockedEnabled: Bool
    ) -> Bool {
        !lockEnabled || spotlightWhileLockedEnabled
    }
}
