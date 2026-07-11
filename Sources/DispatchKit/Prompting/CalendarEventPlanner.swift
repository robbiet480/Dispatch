import Foundation

/// Per-group event-matching rule for the `calendarEventEnd` schedule kind
/// (plan 31) — the first event kind carrying configuration (visit/workout
/// carry none). Stored on `PromptGroup` as three additive optional fields
/// (`calendarMatchKindRaw` / `calendarIdentifiersJSON` /
/// `calendarTitleFilter`); the raw-kind codec below owns that mapping so the
/// model's `schedule` accessor stays a thin switch. The kit never imports
/// EventKit — the app maps `EKEvent`s into `CalendarEventCandidate`s and the
/// matching here is pure, unit-testable string/ID work.
public enum CalendarEventMatchRule: Equatable, Sendable {
    /// Every (non-all-day) event on any calendar.
    case allEvents
    /// Events on specific calendars, by EKCalendar `calendarIdentifier`.
    /// `.calendars([])` matches nothing — degenerate configs fail safe (the
    /// editor prevents saving one).
    case calendars([String])
    /// Events whose title contains the filter, case- and
    /// diacritic-insensitively. The editor normalizes an empty (trimmed)
    /// filter to `.allEvents` on save; storage-level an empty filter matches
    /// nothing (fails safe).
    case titleContains(String)

    /// Storage kind raws. `.allEvents` is stored as nil fields (the
    /// `PromptGroup.schedule` setter nils all three), but the "allEvents"
    /// raw is accepted on read for wire tolerance.
    static let allEventsRaw = "allEvents"
    static let calendarsRaw = "calendars"
    static let titleContainsRaw = "titleContains"

    /// Resolves the stored raw fields; nil for an UNKNOWN kind raw (a future
    /// rule synced from a newer build) so the caller can fall back to
    /// `.disabled` — never fires rather than misfires, raws preserved.
    public init?(kindRaw: String?, identifiersJSON: String?, titleFilter: String?) {
        switch kindRaw {
        case nil, Self.allEventsRaw:
            self = .allEvents
        case Self.calendarsRaw:
            self = .calendars(Self.identifiers(fromJSON: identifiersJSON))
        case Self.titleContainsRaw:
            self = .titleContains(titleFilter ?? "")
        default:
            return nil
        }
    }

    /// The stored kind raw; nil for `.allEvents` (nil-fields storage form).
    public var kindRaw: String? {
        switch self {
        case .allEvents: nil
        case .calendars: Self.calendarsRaw
        case .titleContains: Self.titleContainsRaw
        }
    }

    /// JSON-encoded `[String]` of calendar identifiers (the
    /// `scheduledTimesJSON` codec pattern); nil for other rules.
    public var identifiersJSON: String? {
        guard case .calendars(let ids) = self else { return nil }
        return Self.json(fromIdentifiers: ids)
    }

    /// The title filter; nil for other rules.
    public var titleFilter: String? {
        guard case .titleContains(let filter) = self else { return nil }
        return filter
    }

    /// Pure matching table. Title matching is case- and diacritic-insensitive
    /// (`range(of:options:)`) so "standup" matches "Daily Standup" and
    /// "STANDÜP"; nil titles/IDs never match a specific rule.
    public func matches(calendarID: String?, title: String?) -> Bool {
        switch self {
        case .allEvents:
            return true
        case .calendars(let ids):
            guard let calendarID else { return false }
            return ids.contains(calendarID)
        case .titleContains(let filter):
            guard let title else { return false }
            return title.range(
                of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - JSON [String] codec

    static func identifiers(fromJSON json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    static func json(fromIdentifiers identifiers: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(identifiers) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A calendar event's prompt-relevant slice — a plain Sendable struct the app
/// maps `EKEvent`s into, so DispatchKit stays EventKit-free and the planning
/// below runs under `swift test`.
public struct CalendarEventCandidate: Equatable, Sendable {
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String?
    public let title: String?

    public init(end: Date, isAllDay: Bool, calendarID: String?, title: String?) {
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.title = title
    }
}

/// Pure event-end fire-date planning (plan 31). Calendar prompts are
/// SCHEDULED AHEAD — EventKit has no background wake, so at every replan the
/// scheduler turns matching events' end dates into ordinary content-addressed
/// `gprompt-` requests within the existing plan windows.
public enum CalendarEventPlanner {
    /// Fire dates for one group's rule over the fetched candidates:
    ///
    /// - **All-day events are excluded** (`isAllDay`): an end-of-day prompt
    ///   at midnight is noise, and all-day "events" aren't attended things
    ///   (decided + logged in the plan doc).
    /// - Only ends strictly after `now` fire — which deliberately KEEPS an
    ///   event already in progress whose end is still in the future.
    /// - Ends must land inside `[windowStart, windowEnd)` — the awake plan
    ///   window; the asleep replan guard already schedules nothing, matching
    ///   every other prompt family.
    /// - Sorted ascending, deduped at MINUTE granularity: the `gprompt` stamp
    ///   is minute-resolution, so two events ending in the same minute would
    ///   collide on the content-addressed identifier anyway — the dedupe
    ///   (keeping the earliest end in the minute) makes that deliberate.
    public static func fireDates(
        candidates: [CalendarEventCandidate],
        rule: CalendarEventMatchRule,
        now: Date,
        windowStart: Date,
        windowEnd: Date
    ) -> [Date] {
        let kept = candidates
            .filter { candidate in
                !candidate.isAllDay
                    && candidate.end > now
                    && candidate.end >= windowStart
                    && candidate.end < windowEnd
                    && rule.matches(calendarID: candidate.calendarID, title: candidate.title)
            }
            .map(\.end)
            .sorted()
        var seenMinutes = Set<Int>()
        return kept.filter { date in
            seenMinutes.insert(Int(floor(date.timeIntervalSinceReferenceDate / 60))).inserted
        }
    }
}
