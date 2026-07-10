import Foundation

/// The watch's handling of actions on prompt notifications FORWARDED from
/// the phone (plan 19 design §v1-scope-5) — the unit-testable mapping,
/// separated from the UNUserNotificationCenter delegate glue in the watch
/// target.
///
/// The watch registers no categories and schedules NOTHING; the category
/// (and its buttons) comes from the phone's registration and the system's
/// forwarding. Action identifiers therefore MIRROR the phone's
/// `NotificationIdentifiers` (App/Sources/Notifications/
/// NotificationScheduler.swift) — keep the two in sync.
public enum WatchNotificationAction: Equatable, Sendable {
    /// Yes/No FILE directly on the watch via the shared filing path —
    /// one tap must mean one filed answer, never open-a-screen.
    case fileAnswer(isYes: Bool)
    /// Snooze is a documented NO-OP on the watch: the watch is banned from
    /// scheduling (watch-local notifications don't dedup against the
    /// phone's local prompts) and cannot reach the phone's scheduler — a
    /// relay is deferred scope. The nag chain, if any, keeps running
    /// phone-side. Dismiss + log is the v1 contract.
    case snoozeNoOp
    /// Plain tap (default action) — open the app to the question (the
    /// watch home leads with the quick-answer question).
    case openApp

    /// Mirrors of the phone's registered action identifiers.
    public static let answerYesIdentifier = "answer-yes"
    public static let answerNoIdentifier = "answer-no"
    public static let snoozeIdentifier = "snooze"

    /// Maps a UNNotificationResponse.actionIdentifier to the watch behavior.
    /// Default and unknown identifiers (including
    /// UNNotificationDefaultActionIdentifier and future phone-side actions
    /// this build doesn't know) open the app — the safe fallback.
    public static func route(actionIdentifier: String) -> WatchNotificationAction {
        switch actionIdentifier {
        case answerYesIdentifier: .fileAnswer(isYes: true)
        case answerNoIdentifier: .fileAnswer(isYes: false)
        case snoozeIdentifier: .snoozeNoOp
        default: .openApp
        }
    }
}
