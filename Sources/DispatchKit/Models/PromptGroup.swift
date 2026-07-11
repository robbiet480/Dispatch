import Foundation
import SwiftData

/// How a prompt group is scheduled. Raw values are the stored/exported
/// `scheduleKindRaw` strings — additive only, never repurpose one.
public enum GroupScheduleKind: String, Codable, CaseIterable, Sendable {
    case everyNHours
    case timesPerDay
    case dailyAt
    case workoutEnd
    case visitArrival
    case calendarEventEnd
    case placeTrigger
    case beaconTrigger
}

/// A prompt group's resolved schedule. `disabled` is the fallback for an
/// unknown stored raw value (e.g. a future schedule kind synced back from a
/// newer build) — the group simply never fires rather than misfiring.
public enum GroupSchedule: Equatable, Sendable {
    case everyNHours(Int)
    case timesPerDay(count: Int, distribution: PromptDistribution)
    case dailyAt([DateComponents])
    case workoutEnd
    case visitArrival
    /// A matching calendar event ends (plan 31) — the first event kind with
    /// an associated value: the matching rules are per-group configuration.
    case calendarEventEnd(CalendarEventMatchRule)
    /// Arrival at / departure from a picked place (plan 43, #56) via CLMonitor
    /// `CircularGeographicCondition`, with a configurable delay + cancel.
    case placeTrigger(PlaceTrigger)
    /// Enter/leave range of a registered iBeacon (plan 43, #60) via CLMonitor
    /// `BeaconIdentityCondition`; shares the delay/cancel semantics of #56.
    case beaconTrigger(BeaconTrigger)
    case disabled
}

/// A named group of questions with its own notification schedule, per
/// Angela's feature request (Plan 12). Groups are additive: ungrouped
/// questions keep the global reportKinds + schedule behavior untouched.
///
/// Membership is an ordered ID list (question uniqueIdentifiers), not a
/// SwiftData relationship — CloudKit-safe (optional/defaulted, no #Unique),
/// no relationship-migration risk, and tolerant of dangling IDs, which are
/// skipped at survey time.
@Model
public final class PromptGroup {
    public var uniqueIdentifier: String = UUID().uuidString
    public var name: String = ""
    /// Ordered question uniqueIdentifiers. Dangling IDs are legal.
    public var questionIDs: [String] = []
    public var scheduleKindRaw: String = GroupScheduleKind.timesPerDay.rawValue
    public var scheduleHours: Int?
    public var scheduleCount: Int?
    public var scheduleDistributionRaw: String?
    /// JSON-encoded `[String]` of "HH:mm" times for `.dailyAt`.
    public var scheduledTimesJSON: String?
    public var isEnabled: Bool = true
    public var sortOrder: Int = 0
    /// Calendar-event match rule storage (plan 31), all additive optionals
    /// (CloudKit-safe). Raws "allEvents"/"calendars"/"titleContains" —
    /// `.allEvents` is stored as ALL-NIL fields; an unknown kind raw (a
    /// future rule from a newer build) resolves the schedule to `.disabled`.
    public var calendarMatchKindRaw: String?
    /// JSON-encoded `[String]` of EKCalendar identifiers for `.calendars`
    /// (the `scheduledTimesJSON` codec pattern).
    public var calendarIdentifiersJSON: String?
    /// The `.titleContains` filter string.
    public var calendarTitleFilter: String?
    /// CLMonitor place/beacon trigger storage (plan 43), all additive
    /// optionals (CloudKit-safe). `monitorDirectionRaw` is
    /// "arrival"/"departure"; `monitorDelayMinutes` a `MonitorDelay` preset;
    /// `monitorCancelsOnContradiction` defaults to true when nil. The
    /// condition payload is a JSON blob — `placeRegionJSON` for
    /// `.placeTrigger`, `beaconIdentityJSON` for `.beaconTrigger` (the
    /// `scheduledTimesJSON` codec pattern). A missing/corrupt payload for the
    /// resolved kind → `.disabled` (never fires rather than misfires).
    public var monitorDirectionRaw: String?
    public var monitorDelayMinutes: Int?
    public var monitorCancelsOnContradiction: Bool?
    public var placeRegionJSON: String?
    public var beaconIdentityJSON: String?

    public init() {}

    /// Resolved schedule; unknown `scheduleKindRaw` → `.disabled`.
    public var schedule: GroupSchedule {
        get {
            switch GroupScheduleKind(rawValue: scheduleKindRaw) {
            case .everyNHours:
                return .everyNHours(max(1, scheduleHours ?? 4))
            case .timesPerDay:
                let distribution = scheduleDistributionRaw
                    .flatMap(PromptDistribution.init(rawValue:)) ?? .semiRandom
                return .timesPerDay(count: max(1, scheduleCount ?? 4), distribution: distribution)
            case .dailyAt:
                return .dailyAt(Self.timeComponents(fromJSON: scheduledTimesJSON))
            case .workoutEnd:
                return .workoutEnd
            case .visitArrival:
                return .visitArrival
            case .calendarEventEnd:
                // Unknown match-kind raw (future rule from a newer build) →
                // .disabled: never fires rather than misfires; raws preserved
                // by the .disabled setter no-op below.
                guard let rule = CalendarEventMatchRule(
                    kindRaw: calendarMatchKindRaw,
                    identifiersJSON: calendarIdentifiersJSON,
                    titleFilter: calendarTitleFilter) else { return .disabled }
                return .calendarEventEnd(rule)
            case .placeTrigger:
                // Missing/corrupt payload (or a direction raw from a newer
                // build) → .disabled, raws preserved by the setter no-op.
                guard let trigger = PlaceTrigger(
                    regionJSON: placeRegionJSON,
                    directionRaw: monitorDirectionRaw,
                    delayMinutes: monitorDelayMinutes,
                    cancelOnContradiction: monitorCancelsOnContradiction)
                else { return .disabled }
                return .placeTrigger(trigger)
            case .beaconTrigger:
                guard let trigger = BeaconTrigger(
                    beaconJSON: beaconIdentityJSON,
                    directionRaw: monitorDirectionRaw,
                    delayMinutes: monitorDelayMinutes,
                    cancelOnContradiction: monitorCancelsOnContradiction)
                else { return .disabled }
                return .beaconTrigger(trigger)
            case nil:
                return .disabled
            }
        }
        set {
            switch newValue {
            case .everyNHours(let hours):
                scheduleKindRaw = GroupScheduleKind.everyNHours.rawValue
                scheduleHours = max(1, hours)
            case .timesPerDay(let count, let distribution):
                scheduleKindRaw = GroupScheduleKind.timesPerDay.rawValue
                scheduleCount = max(1, count)
                scheduleDistributionRaw = distribution.rawValue
            case .dailyAt(let times):
                scheduleKindRaw = GroupScheduleKind.dailyAt.rawValue
                scheduledTimesJSON = Self.json(fromTimeComponents: times)
            case .workoutEnd:
                scheduleKindRaw = GroupScheduleKind.workoutEnd.rawValue
            case .visitArrival:
                scheduleKindRaw = GroupScheduleKind.visitArrival.rawValue
            case .calendarEventEnd(let rule):
                scheduleKindRaw = GroupScheduleKind.calendarEventEnd.rawValue
                // .allEvents nils all three fields (its storage form).
                calendarMatchKindRaw = rule.kindRaw
                calendarIdentifiersJSON = rule.identifiersJSON
                calendarTitleFilter = rule.titleFilter
            case .placeTrigger(let trigger):
                scheduleKindRaw = GroupScheduleKind.placeTrigger.rawValue
                monitorDirectionRaw = trigger.direction.rawValue
                monitorDelayMinutes = trigger.delayMinutes
                monitorCancelsOnContradiction = trigger.cancelOnContradiction
                placeRegionJSON = trigger.regionJSON
                beaconIdentityJSON = nil
            case .beaconTrigger(let trigger):
                scheduleKindRaw = GroupScheduleKind.beaconTrigger.rawValue
                monitorDirectionRaw = trigger.direction.rawValue
                monitorDelayMinutes = trigger.delayMinutes
                monitorCancelsOnContradiction = trigger.cancelOnContradiction
                beaconIdentityJSON = trigger.beaconJSON
                placeRegionJSON = nil
            case .disabled:
                // Not a storable kind: `.disabled` only arises from an
                // unknown raw value, so writing it back preserves the
                // existing raw (round-trip safety for future kinds).
                break
            }
        }
    }

    /// The `.dailyAt` times as "HH:mm" strings (stable wire/storage form).
    public var scheduledTimeStrings: [String] {
        get { Self.timeStrings(fromJSON: scheduledTimesJSON) }
        set { scheduledTimesJSON = try? String(data: JSONEncoder().encode(newValue), encoding: .utf8) }
    }

    // MARK: - "HH:mm" codec

    /// Parses "HH:mm" into hour/minute DateComponents; nil for malformed input.
    public static func timeComponents(fromString string: String) -> DateComponents? {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    public static func timeString(fromComponents components: DateComponents) -> String {
        String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func timeStrings(fromJSON json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings
    }

    static func timeComponents(fromJSON json: String?) -> [DateComponents] {
        timeStrings(fromJSON: json).compactMap(timeComponents(fromString:))
    }

    static func json(fromTimeComponents components: [DateComponents]) -> String? {
        let strings = components.map(timeString(fromComponents:))
        guard let data = try? JSONEncoder().encode(strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
