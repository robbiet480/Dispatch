import Foundation
import Testing

@testable import DispatchKit

@Suite("CaptureWindow")
struct CaptureWindowTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("nil anchor degrades to absent")
    func nilAnchor() {
        #expect(CaptureWindow.compute(anchor: nil, now: now) == nil)
    }

    @Test("anchor equal to now degrades to absent")
    func anchorEqualToNow() {
        #expect(CaptureWindow.compute(anchor: now, now: now) == nil)
    }

    @Test("anchor in the future degrades to absent")
    func futureAnchor() {
        #expect(CaptureWindow.compute(anchor: now.addingTimeInterval(60), now: now) == nil)
    }

    @Test("normal anchor spans anchor to now, unclamped")
    func normalAnchor() {
        let anchor = now.addingTimeInterval(-47 * 60)
        let window = CaptureWindow.compute(anchor: anchor, now: now)
        #expect(window == CaptureWindow(start: anchor, end: now, isClamped: false))
    }

    @Test("anchor at exactly the cap is unclamped")
    func anchorAtCap() {
        let anchor = now.addingTimeInterval(-CaptureWindow.defaultCap)
        let window = CaptureWindow.compute(anchor: anchor, now: now)
        #expect(window == CaptureWindow(start: anchor, end: now, isClamped: false))
    }

    @Test("anchor older than the cap clamps to the trailing cap")
    func clampedAnchor() {
        let anchor = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let window = CaptureWindow.compute(anchor: anchor, now: now)
        #expect(window == CaptureWindow(start: now.addingTimeInterval(-CaptureWindow.defaultCap),
                                        end: now, isClamped: true))
    }

    @Test("non-positive cap degrades to absent")
    func nonPositiveCap() {
        let anchor = now.addingTimeInterval(-60)
        #expect(CaptureWindow.compute(anchor: anchor, now: now, cap: 0) == nil)
        #expect(CaptureWindow.compute(anchor: anchor, now: now, cap: -1) == nil)
    }

    @Test("default cap is 24 hours")
    func defaultCap() {
        #expect(CaptureWindow.defaultCap == 24 * 60 * 60)
    }
}
