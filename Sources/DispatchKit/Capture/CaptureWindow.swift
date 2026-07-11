import Foundation

/// The statistics window for change-since-anchor sensor captures (plan 43,
/// issue #48). The anchor is a PARAMETER — today the caller passes the
/// previous report's date, but place/beacon triggers (#56/#60) can pass an
/// arrival time instead; nothing here assumes "previous report".
///
/// Degrade rules (decided in the plan doc):
/// - No anchor (first report ever), or an anchor not strictly in the past
///   (clock skew), yields nil — the sensor degrades to absent, never to a
///   fabricated start-of-day window or a fake zero.
/// - Windows longer than `cap` clamp to the trailing cap so "since last
///   report" stays meaningful after days away; `isClamped` records that the
///   window does NOT reach back to the anchor.
public struct CaptureWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let isClamped: Bool

    /// 24 hours — beyond this, min/max/delta "since last report" stops being
    /// a useful summary and the query cost grows for no insight.
    public static let defaultCap: TimeInterval = 24 * 60 * 60

    public init(start: Date, end: Date, isClamped: Bool) {
        self.start = start
        self.end = end
        self.isClamped = isClamped
    }

    /// Computes the window from `anchor` to `now`, or nil when no honest
    /// window exists (no anchor, anchor >= now, or a non-positive cap).
    public static func compute(anchor: Date?, now: Date,
                               cap: TimeInterval = defaultCap) -> CaptureWindow? {
        guard let anchor, anchor < now, cap > 0 else { return nil }
        let earliest = now.addingTimeInterval(-cap)
        if anchor < earliest {
            return CaptureWindow(start: earliest, end: now, isClamped: true)
        }
        return CaptureWindow(start: anchor, end: now, isClamped: false)
    }
}
