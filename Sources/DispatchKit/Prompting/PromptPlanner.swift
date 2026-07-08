import Foundation

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum PromptPlanner {
    static func plan(
        prefs: NotificationPrefs,
        awakeStart: Date,
        awakeEnd: Date,
        seed: UInt64,
        calendar: Calendar = .current
    ) -> [Date] {
        var generator = SeededGenerator(seed: seed)
        let windowDuration = awakeEnd.timeIntervalSince(awakeStart)
        let alertCount = prefs.alertsPerDay
        var dates: [Date] = []

        // Generate times based on distribution
        switch prefs.distribution {
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

        // Materialize scheduled times and append
        let startDay = calendar.startOfDay(for: awakeStart)
        for timeComponent in prefs.scheduledTimes {
            var dateComponent = DateComponents()
            dateComponent.hour = timeComponent.hour
            dateComponent.minute = timeComponent.minute

            if let scheduledDate = calendar.date(byAdding: dateComponent, to: startDay),
               scheduledDate >= awakeStart && scheduledDate < awakeEnd {
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
