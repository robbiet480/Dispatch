import Foundation
import SwiftData

/// The quick-answer question as the widget timeline renders it — a plain
/// value snapshot of the `Question` (the entry can't hold a live SwiftData
/// model), plus the two button titles resolved with the same fallback the
/// filing path uses.
public struct QuickAnswerQuestion: Codable, Equatable, Sendable {
    public var questionID: String
    public var prompt: String
    public var yesTitle: String
    public var noTitle: String

    public init(questionID: String, prompt: String, yesTitle: String, noTitle: String) {
        self.questionID = questionID
        self.prompt = prompt
        self.yesTitle = yesTitle
        self.noTitle = noTitle
    }

    public init(question: Question) {
        questionID = question.uniqueIdentifier
        prompt = question.prompt
        yesTitle = question.choices.first ?? "Yes"
        noTitle = question.choices.count > 1 ? question.choices[1] : "No"
    }
}

/// App Group defaults markers bridging the widget quick-answer intent
/// (which runs in the WIDGET EXTENSION process — probe-verified, see
/// QuickAnswerIntent) back to the app.
///
/// Why markers: the extension process CANNOT reach two of the filing side
/// effects directly — `NotificationPrefs.lastActedAt` lives in the app's
/// `.standard` defaults (app sandbox), and `UNUserNotificationCenter`
/// pending-request removal manages the EXTENSION's notification identity,
/// not the app's, so the nag chain can't be cancelled from there. The
/// intent therefore persists `pendingActedAt` here and the app drains it
/// at next launch/foreground (`NotificationScheduler
/// .drainWidgetQuickAnswerActions`), applying `lastActedAt` and the stale
/// nag removal exactly as an in-app report save would.
public enum WidgetQuickAnswerMarker {
    /// When the widget intent last filed an answer the app hasn't yet
    /// acknowledged (drained). Absent when there is nothing pending.
    public static let pendingActedAtKey = "widget.quickAnswerPendingActedAt"
    /// When the widget intent last filed an answer at all — drives the
    /// transient "Filed ✓" state in the widget UI. Never cleared by the
    /// app; the widget stops honoring it after `filedDisplayDuration`.
    public static let filedAtKey = "widget.quickAnswerFiledAt"

    /// How long the widget shows "Filed ✓" instead of the answer buttons.
    public static let filedDisplayDuration: TimeInterval = 10 * 60

    /// How long after a widget filing a second intent invocation is treated
    /// as a double-fire of the same tap burst rather than a new answer
    /// (build-14 review: two rapid taps each ran `perform()` and filed two
    /// reports before the first reload replaced the buttons with "Filed ✓").
    public static let doubleFireSuppressionWindow: TimeInterval = 8

    /// Whether a quick-answer filing at `now` should be suppressed as a
    /// double-fire, given the last widget filing (`filedAt` marker). Also
    /// tolerates clock rollback: a future-dated marker does not suppress.
    public static func shouldSuppressDoubleFire(lastFiledAt: Date?, now: Date = Date()) -> Bool {
        guard let lastFiledAt else { return false }
        let elapsed = now.timeIntervalSince(lastFiledAt)
        return elapsed >= 0 && elapsed < doubleFireSuppressionWindow
    }

    /// Records ONLY the nag-cancel (`pendingActedAt`) marker, without the
    /// widget-only `filedAt` marker — for non-widget filing paths (the "Log
    /// Answer" App Intent) that must cancel the question's nag chain at the
    /// app's next foreground but must NOT flip the medium widget's transient
    /// "Filed ✓" state or arm its double-fire suppression window (both keyed
    /// off `filedAt`). `pendingActedAt` only ever moves forward so an
    /// undrained older marker can't regress.
    public static func recordPendingActedAt(at date: Date, in defaults: UserDefaults) {
        if let existing = pendingActedAt(in: defaults), existing >= date {
            // keep the newer pending marker
        } else {
            defaults.set(date.timeIntervalSince1970, forKey: pendingActedAtKey)
        }
    }

    /// Records a widget-filed answer (both markers). `pendingActedAt` only
    /// ever moves forward so an undrained older marker can't regress.
    public static func recordFiled(at date: Date, in defaults: UserDefaults) {
        recordPendingActedAt(at: date, in: defaults)
        defaults.set(date.timeIntervalSince1970, forKey: filedAtKey)
    }

    public static func pendingActedAt(in defaults: UserDefaults) -> Date? {
        let stored = defaults.double(forKey: pendingActedAtKey)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    /// Reads AND clears the pending marker (the drain is one-shot).
    public static func takePendingActedAt(in defaults: UserDefaults) -> Date? {
        guard let date = pendingActedAt(in: defaults) else { return nil }
        defaults.removeObject(forKey: pendingActedAtKey)
        // The read-remove pair above is not atomic: the widget extension can
        // record a newer filing concurrently. Re-check after the remove —
        // if a newer marker is visible now, put it back so the next drain
        // applies it instead of losing that filing's nag-cancel.
        if let newer = pendingActedAt(in: defaults), newer > date {
            defaults.set(newer.timeIntervalSince1970, forKey: pendingActedAtKey)
        }
        return date
    }

    public static func filedAt(in defaults: UserDefaults) -> Date? {
        let stored = defaults.double(forKey: filedAtKey)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    /// Whether the widget should still render the transient "Filed ✓"
    /// state at `now` (also tolerates clock rollback: a future-dated
    /// marker is not "recent").
    public static func filedRecently(in defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard let filed = filedAt(in: defaults) else { return false }
        let elapsed = now.timeIntervalSince(filed)
        return elapsed >= 0 && elapsed < filedDisplayDuration
    }
}
