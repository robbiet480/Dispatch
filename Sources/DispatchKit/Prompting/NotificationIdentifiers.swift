import Foundation

/// Category + action identifiers for the interactive `DISPATCH_PROMPT`
/// notification (quick Yes/No answer + snooze) and the pending-request
/// identifier prefixes used to distinguish re-plannable prompts from
/// one-off snoozes. Lives in the kit (moved from the app's
/// NotificationScheduler) so the pure identifier-parsing logic below is
/// testable under `swift test`.
public enum NotificationIdentifiers {
    public static let category = "DISPATCH_PROMPT"
    public static let answerYesAction = "answer-yes"
    public static let answerNoAction = "answer-no"
    public static let snoozeAction = "snooze"
    /// Global prompts: `prompt-<yyyyMMdd-HHmm>`. The stamp is the planned
    /// fire minute; it does NOT say whether the minute came from the
    /// distribution or a fixed scheduled time — `promptSource` disambiguates
    /// by comparing the fire time against the user's scheduled times.
    public static let promptPrefix = "prompt-"
    public static let snoozePrefix = "snooze-"
    public static let nagPrefix = "nag-"
    /// Group prompts: `gprompt-<groupID>-<yyyyMMdd-HHmm>` (plan 12). Their
    /// nags reuse `nag-` with the `<groupID>-<stamp>` parent stamp embedded.
    public static let groupPromptPrefix = "gprompt-"
    /// Weekly digest reminder (plan 14). One repeating request,
    /// `digest-weekly`; removals join the prompt-/gprompt-/nag- batch.
    public static let digestPrefix = "digest-"
    public static let digestWeeklyIdentifier = "digest-weekly"
    /// Webhook delivery-failure notice (plan 24): `webhook-failed-<reportID>`,
    /// posted by WebhookManager on a report's 3rd failed attempt. Joins the
    /// standard removal-batch prefix discipline (replan batch + the
    /// delete-all removeAll).
    public static let webhookFailedPrefix = "webhook-failed-"
    /// userInfo key carrying the PromptGroup uniqueIdentifier.
    public static let promptGroupIDKey = "promptGroupID"
    /// userInfo key carrying the UUID of the HKWorkout that fired a
    /// workout-end prompt (plan 12 amendment).
    public static let triggeringWorkoutIDKey = "triggeringWorkoutID"
    /// userInfo marker ("1") on prompts fired by a visit arrival (plan 16) —
    /// tap-through reports get the `.visitArrival` trigger.
    public static let visitArrivalKey = "triggeredByVisitArrival"
}

/// Where the next upcoming prompt notification comes from, for the settings
/// UI's "NEXT NOTIFICATION" hero caption.
public enum NextPromptSource: Equatable, Sendable {
    /// A global prompt planned by the distribution (random/semi-random/regular).
    case distribution
    /// A global prompt materialized from a user-fixed scheduled time.
    case scheduledTime
    /// A prompt-group prompt; the caller resolves the group's display name.
    case promptGroup(groupID: String)
    /// A one-off "Snooze 15m" re-delivery of a prompt.
    case snooze
}

extension NotificationIdentifiers {
    /// Classifies a pending-request identifier as an upcoming PROMPT and
    /// says where it came from, or returns nil for requests that are not a
    /// "next prompt": nag reminders (follow-ups about an already-delivered
    /// prompt, deliberately excluded — the hero shows the next prompt, not
    /// a reminder about an old one), the weekly digest, webhook-failure
    /// notices, and anything unrecognized.
    ///
    /// Global `prompt-` identifiers encode only the fire minute, so
    /// distribution vs scheduled-time is decided by matching `fireDate`'s
    /// hour:minute against `scheduledTimes` (the planner dedupes at minute
    /// granularity, so a collision is labeled as the scheduled time — the
    /// user did ask for that minute).
    public static func promptSource(
        forIdentifier identifier: String,
        fireDate: Date,
        scheduledTimes: [DateComponents],
        calendar: Calendar = .current
    ) -> NextPromptSource? {
        if identifier.hasPrefix(promptPrefix) {
            let hour = calendar.component(.hour, from: fireDate)
            let minute = calendar.component(.minute, from: fireDate)
            let matchesScheduled = scheduledTimes.contains {
                ($0.hour ?? 0) == hour && ($0.minute ?? 0) == minute
            }
            return matchesScheduled ? .scheduledTime : .distribution
        }
        if identifier.hasPrefix(groupPromptPrefix) {
            // `gprompt-<groupID>-<yyyyMMdd>-<HHmm>`: the group ID is a UUID
            // and itself contains dashes, so the stamp's date is always the
            // LAST two dash-separated segments and the group ID is
            // everything before them.
            let stamp = String(identifier.dropFirst(groupPromptPrefix.count))
            let segments = stamp.split(separator: "-")
            guard segments.count > 2 else { return nil }
            return .promptGroup(groupID: segments.dropLast(2).joined(separator: "-"))
        }
        if identifier.hasPrefix(snoozePrefix) {
            return .snooze
        }
        return nil
    }
}
