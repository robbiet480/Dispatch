import Foundation

/// Pure formatting for the workout that fired a workout-end group prompt
/// (plan 12 amendment). The triggering workout's details are stored as
/// additive HealthReadings: `workout.trigger.type` (HKWorkoutActivityType
/// raw), `workout.trigger.duration` (s), and — when present —
/// `workout.trigger.energy` (kcal), `workout.trigger.distance` (m),
/// `workout.trigger.avgHeartRate` (bpm). No HealthKit import.
public enum TriggeredWorkoutSummary {
    public static let typeReading = "workout.trigger.type"
    public static let durationReading = "workout.trigger.duration"
    public static let energyReading = "workout.trigger.energy"
    public static let distanceReading = "workout.trigger.distance"
    public static let avgHeartRateReading = "workout.trigger.avgHeartRate"

    /// "Running — 32m 10s · 412 kcal · 5.2 km · 148 bpm avg", omitting
    /// absent metrics. nil when there is no `workout.trigger.type` reading
    /// (i.e. the report was not triggered by a workout, or the workout
    /// couldn't be re-fetched and capture degraded to plain workoutEnd).
    public static func line(from readings: [HealthReading]) -> String? {
        guard let rawType = value(typeReading, in: readings) else { return nil }
        let name = WorkoutActivityName.displayName(forRawValue: UInt(max(0, rawType.rounded())))

        var metrics: [String] = []
        if let duration = value(durationReading, in: readings) {
            metrics.append(formatDuration(duration))
        }
        if let energy = value(energyReading, in: readings) {
            metrics.append("\(Int(energy.rounded())) kcal")
        }
        if let meters = value(distanceReading, in: readings) {
            metrics.append(String(format: "%.1f km", meters / 1000))
        }
        if let bpm = value(avgHeartRateReading, in: readings) {
            metrics.append("\(Int(bpm.rounded())) bpm avg")
        }
        return metrics.isEmpty ? name : "\(name) — \(metrics.joined(separator: " · "))"
    }

    private static func value(_ type: String, in readings: [HealthReading]) -> Double? {
        readings.first { $0.type == type }?.value
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60)m \(total % 60)s"
    }
}
