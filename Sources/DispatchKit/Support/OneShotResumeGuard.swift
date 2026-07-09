import Foundation
import os

/// One-shot gate for resuming a `CheckedContinuation` from a callback that a
/// framework may invoke more than once. Swift traps (EXC_BREAKPOINT) on the
/// second resume of a checked continuation — the build-8 launch crash was
/// exactly this: CMPedometer's query completion handler fired twice on an
/// iOS 27 beta and double-resumed the Motion permission continuation.
///
/// Usage: create one guard per continuation and only resume when `claim()`
/// returns true. Safe to call any number of times, from any thread/queue.
///
/// Same take-once semantics as `CaptureCoordinator`'s inline
/// `OSAllocatedUnfairLock` resumeOnce and `CascadeLocationRequester`'s
/// resumeIfNeeded, extracted so callback-based permission/query shims can
/// share (and tests can exercise) a single implementation.
public final class OneShotResumeGuard: Sendable {
    private let resumed = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Returns true exactly once across all callers; every subsequent call
    /// returns false. The caller resumes its continuation only on true.
    public func claim() -> Bool {
        resumed.withLock { already in
            if already { return false }
            already = true
            return true
        }
    }
}
