import DispatchKit
import Foundation
import Testing

/// Queue-until-unlocked semantics for URLs opened behind the app lock /
/// privacy cover (the Spotify OAuth callback return path).
@Suite struct LockedURLQueueTests {
    private let callback = URL(string: "dispatch-spotify://callback?code=abc")!
    private let widget = URL(string: "dispatch://report")!

    @Test func routesImmediatelyWhenNeitherLockedNorCovered() {
        var queue = LockedURLQueue()
        let deferred = queue.deferIfNeeded(callback, isLocked: false, isCovered: false)
        #expect(!deferred)
        #expect(queue.pendingURLs.isEmpty)
        let drained = queue.drain()
        #expect(drained.isEmpty)
    }

    @Test func defersWhenLocked() {
        var queue = LockedURLQueue()
        let deferred = queue.deferIfNeeded(callback, isLocked: true, isCovered: false)
        #expect(deferred)
        #expect(queue.pendingURLs == [callback])
    }

    @Test func defersWhenCoveredButNotYetLocked() {
        // The OAuth callback can arrive before the foreground-return lock
        // decision, while only the privacy cover is up — it must still queue.
        var queue = LockedURLQueue()
        let deferred = queue.deferIfNeeded(callback, isLocked: false, isCovered: true)
        #expect(deferred)
        #expect(queue.pendingURLs == [callback])
    }

    @Test func drainReturnsArrivalOrderAndEmpties() {
        var queue = LockedURLQueue()
        _ = queue.deferIfNeeded(callback, isLocked: true, isCovered: false)
        _ = queue.deferIfNeeded(widget, isLocked: true, isCovered: false)
        let drained = queue.drain()
        #expect(drained == [callback, widget])
        #expect(queue.pendingURLs.isEmpty)
        let secondDrain = queue.drain()
        #expect(secondDrain.isEmpty)
    }

    @Test func failedUnlockKeepsURLQueued() {
        // A cancelled/failed unlock never drains — the URL survives for the
        // next unlock attempt (the token exchange must not be dropped).
        var queue = LockedURLQueue()
        _ = queue.deferIfNeeded(callback, isLocked: true, isCovered: false)
        // No drain() between attempts — still queued.
        #expect(queue.pendingURLs == [callback])
        _ = queue.deferIfNeeded(widget, isLocked: true, isCovered: false)
        let drained = queue.drain()
        #expect(drained == [callback, widget])
    }
}
