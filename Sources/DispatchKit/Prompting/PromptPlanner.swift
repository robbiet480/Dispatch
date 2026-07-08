import Foundation

public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public enum PromptPlanner {
    public static func plan(
        prefs: NotificationPrefs,
        awakeStart: Date,
        awakeEnd: Date,
        seed: UInt64,
        calendar: Calendar = .current
    ) -> [Date] {
        plan(alertsPerDay: prefs.alertsPerDay,
             distribution: prefs.distribution,
             scheduledTimes: prefs.scheduledTimes,
             awakeStart: awakeStart, awakeEnd: awakeEnd,
             seed: seed, calendar: calendar)
    }

    /// Parameterized core (plan 12): prompt groups reuse the same
    /// distribution machinery without a UserDefaults-backed prefs object.
    /// `alertsPerDay: 0` skips distribution planning entirely and only
    /// materializes `scheduledTimes` (the dailyAt group schedule).
    public static func plan(
        alertsPerDay: Int,
        distribution: PromptDistribution,
        scheduledTimes: [DateComponents],
        awakeStart: Date,
        awakeEnd: Date,
        seed: UInt64,
        calendar: Calendar = .current
    ) -> [Date] {
        var generator = SeededGenerator(seed: seed)
        let windowDuration = awakeEnd.timeIntervalSince(awakeStart)
        let alertCount = alertsPerDay
        var dates: [Date] = []

        // Generate times based on distribution
        switch alertCount > 0 ? distribution : nil {
        case nil:
            break
        case .random:
            // Generate random times uniformly within the window
            for _ in 0..<alertCount {
                let randomOffset = Double.random(in: 0..<windowDuration, using: &generator)
                let date = awakeStart.addingTimeInterval(randomOffset)
                dates.append(date)
            }

        case .semiRandom:
            // Divide window into slots, put one random alert per slot
            let slotDuration = windowDuration / Double(alertCount)
            for i in 0..<alertCount {
                let slotStart = Double(i) * slotDuration
                let slotEnd = Double(i + 1) * slotDuration
                let randomOffset = Double.random(in: slotStart..<slotEnd, using: &generator)
                let date = awakeStart.addingTimeInterval(randomOffset)
                dates.append(date)
            }

        case .regular:
            // Evenly spaced alerts
            let interval = windowDuration / Double(alertCount)
            for i in 0..<alertCount {
                let offset = Double(i) * interval
                let date = awakeStart.addingTimeInterval(offset)
                dates.append(date)
            }
        }

        // Sort the dates
        dates.sort()

        // Materialize scheduled times and append.
        // A scheduled time-of-day is first tried on awakeStart's calendar day. If that
        // lands outside [awakeStart, awakeEnd) — e.g. an awake window that crosses
        // midnight, like 22:00 -> 06:00, with a scheduled time of 02:00 — retry on the
        // next calendar day before giving up, since the intended occurrence may fall
        // on the following day within the window.
        let startDay = calendar.startOfDay(for: awakeStart)
        for timeComponent in scheduledTimes {
            var dateComponent = DateComponents()
            dateComponent.hour = timeComponent.hour
            dateComponent.minute = timeComponent.minute

            var resolvedDate: Date?
            if let candidate = calendar.date(byAdding: dateComponent, to: startDay),
               candidate >= awakeStart && candidate < awakeEnd {
                resolvedDate = candidate
            } else if let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay),
                      let candidate = calendar.date(byAdding: dateComponent, to: nextDay),
                      candidate >= awakeStart && candidate < awakeEnd {
                resolvedDate = candidate
            }

            if let scheduledDate = resolvedDate {
                // Check for minute-level duplicates
                let scheduledMinute = calendar.component(.minute, from: scheduledDate)
                let scheduledHour = calendar.component(.hour, from: scheduledDate)
                let isDuplicate = dates.contains { date in
                    calendar.component(.hour, from: date) == scheduledHour &&
                    calendar.component(.minute, from: date) == scheduledMinute
                }
                if !isDuplicate {
                    dates.append(scheduledDate)
                }
            }
        }

        // Final sort
        dates.sort()
        return dates
    }
}
