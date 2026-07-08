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
}
