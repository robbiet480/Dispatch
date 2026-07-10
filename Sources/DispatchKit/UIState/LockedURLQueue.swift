import Foundation

/// Queue-until-unlocked buffer for URLs opened while the app lock (or the
/// backgrounding privacy cover) is up. Extracted from the app's URL routing
/// so the defer/drain semantics are independently testable:
///
/// - A URL arriving while locked OR covered is deferred, never dropped —
///   the Spotify OAuth callback token exchange must still complete after
///   the user authenticates.
/// - A failed or cancelled unlock leaves the queue intact; only an explicit
///   `drain()` (called on successful unlock, or on returning to foreground
///   without locking) empties it.
/// - Drain order is arrival order.
public struct LockedURLQueue: Sendable {
    public private(set) var pendingURLs: [URL] = []

    public init() {}

    /// Defers `url` when the app is locked or covered. Returns `true` when
    /// the URL was queued (caller must NOT route it now), `false` when the
    /// app is fully visible and the URL should be routed immediately.
    public mutating func deferIfNeeded(_ url: URL, isLocked: Bool, isCovered: Bool) -> Bool {
        guard isLocked || isCovered else { return false }
        pendingURLs.append(url)
        return true
    }

    /// Returns all queued URLs in arrival order and empties the queue.
    public mutating func drain() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }
}
