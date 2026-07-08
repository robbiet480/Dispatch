import Foundation
import SwiftData

/// How a prompt group is scheduled. Raw values are the stored/exported
/// `scheduleKindRaw` strings — additive only, never repurpose one.
public enum GroupScheduleKind: String, Codable, CaseIterable, Sendable {
    case everyNHours
    case timesPerDay
    case dailyAt
    case workoutEnd
}

/// A prompt group's resolved schedule. `disabled` is the fallback for an
/// unknown stored raw value (e.g. a future schedule kind synced back from a
/// newer build) — the group simply never fires rather than misfiring.
public enum GroupSchedule: Equatable, Sendable {
    case everyNHours(Int)
    case timesPerDay(count: Int, distribution: PromptDistribution)
    case dailyAt([DateComponents])
    case workoutEnd
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
