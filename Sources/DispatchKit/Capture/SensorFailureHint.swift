import Foundation

/// Maps a sensor's failure state to a one-line, actionable hint shown when a
/// tester taps an "UNABLE TO DETECT" or "OFF" row in the capture checklist.
/// Pure mapping — no framework imports, no side effects.
public enum SensorFailureHint {
    /// Hint for a sensor the user has disabled in Settings → Sensors.
    public static func disabledHint(for kind: SensorKind) -> String {
        "Turn \(label(for: kind)) back on in Settings → Sensors."
    }

    /// Hint for a sensor that failed to capture, given the optional reason
    /// string captured on `SensorOutcome.unavailable(reason:)`.
    public static func hint(for kind: SensorKind, reason: String?) -> String {
        switch kind {
        case .healthSteps, .healthFlights, .healthHeart, .healthHRV, .healthRestingHeart,
             .healthSleep, .healthWorkouts, .healthCaffeine, .healthMedications,
             .healthActivityRings, .healthHeartRange:
            return "Check Health → Data Access & Devices → Dispatch."
        case .location:
            return "Allow location access for Dispatch in Settings."
        case .weather:
            return "Check your connection."
        case .audio:
            return "Allow microphone access for Dispatch in Settings."
        case .photos:
            return "Allow photo access for Dispatch in Settings."
        case .focus:
            return "Allow Focus status access for Dispatch in Settings."
        case .altitude, .battery, .connection, .media:
            if let reason, !reason.isEmpty {
                return reason
            }
            return "Unable to detect \(label(for: kind))."
        }
    }

    private static func label(for kind: SensorKind) -> String {
        switch kind {
        case .location: "Location"
        case .weather: "Weather"
        case .altitude: "Altitude"
        case .photos: "Photos"
        case .audio: "Audio"
        case .battery: "Battery"
        case .connection: "Connection"
        case .focus: "Focus"
        case .healthSteps: "Steps"
        case .healthFlights: "Flights Climbed"
        case .healthHeart: "Heart Rate"
        case .healthHeartRange: "Heart Rate Range"
        case .healthHRV: "Heart Rate Variability"
        case .healthRestingHeart: "Resting Heart Rate"
        case .healthSleep: "Sleep"
        case .healthWorkouts: "Workouts"
        case .healthCaffeine: "Caffeine"
        case .healthMedications: "Medications"
        case .healthActivityRings: "Activity Rings"
        case .media: "Media"
        }
    }
}
