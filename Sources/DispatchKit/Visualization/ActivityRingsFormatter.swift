import Foundation

/// Pure formatting for Activity Ring readings (plan 12). Rings are stored as
/// six numeric HealthReadings — `activity.move`/`activity.moveGoal` (kcal),
/// `activity.exercise`/`activity.exerciseGoal` (min),
/// `activity.stand`/`activity.standGoal` (hours) — so they stay viz-able.
/// No HealthKit import: unit-testable everywhere.
public enum ActivityRingsFormatter {
    public static let readingTypes = [
        "activity.move", "activity.moveGoal",
        "activity.exercise", "activity.exerciseGoal",
        "activity.stand", "activity.standGoal",
    ]

    /// Detail-row line: "Move 320/500 · Exercise 22/30 · Stand 9/12".
    /// Rings with no reading are omitted; nil when no ring readings exist.
    public static func summary(from readings: [HealthReading]) -> String? {
        let parts = [
            ringPart("Move", "activity.move", "activity.moveGoal", readings),
            ringPart("Exercise", "activity.exercise", "activity.exerciseGoal", readings),
            ringPart("Stand", "activity.stand", "activity.standGoal", readings),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Capture-checklist line: "MOVE 320/500 KCAL". nil when there is no
    /// move reading (the checklist falls back to its generic captured text).
    public static func checklistLine(from readings: [HealthReading]) -> String? {
        guard let move = value("activity.move", in: readings) else { return nil }
        if let goal = value("activity.moveGoal", in: readings), goal > 0 {
            return "MOVE \(format(move))/\(format(goal)) KCAL"
        }
        return "MOVE \(format(move)) KCAL"
    }

    private static func ringPart(_ label: String, _ valueType: String, _ goalType: String,
                                 _ readings: [HealthReading]) -> String? {
        guard let actual = value(valueType, in: readings) else { return nil }
        if let goal = value(goalType, in: readings), goal > 0 {
            return "\(label) \(format(actual))/\(format(goal))"
        }
        return "\(label) \(format(actual))"
    }

    private static func value(_ type: String, in readings: [HealthReading]) -> Double? {
        readings.first { $0.type == type }?.value
    }

    private static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
