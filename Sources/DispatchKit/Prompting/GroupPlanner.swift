import Foundation

/// Pure, deterministic per-group prompt planning (plan 12). Timer-scheduled
/// groups produce concrete fire dates within an awake window; event-scheduled
/// (and unknown/disabled) groups are never timer-planned and return [].
public enum GroupPlanner {
    /// Plans one group's fire dates within [awakeStart, awakeEnd).
    ///
    /// - `everyNHours(n)`: fires every n hours counted from awakeStart —
    ///   awakeStart + n, + 2n, ... strictly inside the window. The wake
    ///   moment itself is not a fire (prompting at the instant the awake
    ///   window opens would be noise).
    /// - `timesPerDay`: delegates to the PromptPlanner distribution
    ///   machinery. The seed is varied by a stable hash of the group ID so
    ///   different groups (and the global schedule) don't fire simultaneously.
    /// - `dailyAt`: materializes each time within the window, retrying on
    ///   the next calendar day for windows that cross midnight (same
    ///   semantics as the global scheduledTimes).
    /// - `workoutEnd` / `visitArrival` / `disabled`: [] — event-driven or inert.
    public static func plan(
        group: PromptGroup,
        awakeStart: Date,
        awakeEnd: Date,
        seed: UInt64,
        calendar: Calendar = .current
    ) -> [Date] {
        guard awakeEnd > awakeStart else { return [] }
        switch group.schedule {
        case .everyNHours(let hours):
            let step = TimeInterval(max(1, hours)) * 3600
            var dates: [Date] = []
            var candidate = awakeStart.addingTimeInterval(step)
            while candidate < awakeEnd {
                dates.append(candidate)
                candidate = candidate.addingTimeInterval(step)
            }
            return dates

        case .timesPerDay(let count, let distribution):
            return PromptPlanner.plan(
                alertsPerDay: count, distribution: distribution, scheduledTimes: [],
                awakeStart: awakeStart, awakeEnd: awakeEnd,
                seed: seed &+ stableHash(group.uniqueIdentifier), calendar: calendar)

        case .dailyAt(let times):
            return PromptPlanner.plan(
                alertsPerDay: 0, distribution: .regular, scheduledTimes: times,
                awakeStart: awakeStart, awakeEnd: awakeEnd,
                seed: seed, calendar: calendar)

        case .workoutEnd, .visitArrival, .disabled:
            return []
        }
    }

    /// FNV-1a — a stable string hash. Swift's `hashValue` is seeded per
    /// process, which would make schedules churn on every launch.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
