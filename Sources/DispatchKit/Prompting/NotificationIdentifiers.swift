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
    /// Monitor-triggered group prompts (plan 43): `mprompt-<groupID>-<stamp>`.
    /// A DISTINCT prefix from `gprompt-` on purpose — a place/beacon prompt is
    /// scheduled reactively by MonitorObserver (event + delay) and must
    /// SURVIVE the replan's remove-before-add batch, which sweeps
    /// prompt-/gprompt-/nag-/digest-/webhook-failed- but NOT this. The
    /// observer owns its lifecycle: schedule on the fire event, remove by
    /// `mprompt-<groupID>-` prefix on the contradicting event, sweep orphans
    /// on refresh. `promptSource` still classifies it as a group prompt for
    /// the "next notification" hero (same stamp shape as gprompt-).
    public static let monitorPromptPrefix = "mprompt-"
    /// Digest reminders (plan 14, reworked plan 40): one request per schedule,
    /// `digest-<uuid>`; removals join the prompt-/gprompt-/nag- batch. Excluded
    /// from `promptSource` by fall-through — pinned by test. Stale pre-plan-40
    /// `digest-weekly` requests are swept by the same prefix batch on first
    /// replan.
    public static let digestPrefix = "digest-"
    /// userInfo key carrying the digest's `DigestPeriod.rawValue`, so a tap
    /// opens the digest scoped to the schedule's period (week/month/quarter).
    public static let digestPeriodKey = "digestPeriod"
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
    /// userInfo marker ("1") on prompts scheduled at a calendar event's end
    /// (plan 31) — tap-through reports get the `.calendarEventEnd` trigger.
    public static let calendarEventEndKey = "triggeredByCalendarEventEnd"
    /// userInfo markers ("1") on CLMonitor place/beacon prompts (plan 43) —
    /// exactly one is set per prompt so the delegate maps the tap-through
    /// report to the matching `ReportTrigger` (place/beacon × arrival/depart).
    public static let placeArrivalKey = "triggeredByPlaceArrival"
    public static let placeDepartureKey = "triggeredByPlaceDeparture"
    public static let beaconArrivalKey = "triggeredByBeaconArrival"
    public static let beaconDepartureKey = "triggeredByBeaconDeparture"
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
        // `gprompt-`/`mprompt-<groupID>-<yyyyMMdd>-<HHmm>`: the group ID is a
        // UUID and itself contains dashes, so the stamp's date is always the
        // LAST two dash-separated segments and the group ID is everything
        // before them. Monitor prompts (mprompt-) are the same shape.
        for prefix in [groupPromptPrefix, monitorPromptPrefix]
        where identifier.hasPrefix(prefix) {
            let stamp = String(identifier.dropFirst(prefix.count))
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
