import Foundation

/// Pure mapping from an `HKWorkoutActivityType` raw value to a human-readable
/// name. Kept Foundation-only (NO HealthKit import) so it can be unit tested
/// without HealthKit and used from contexts that don't link the framework.
///
/// Raw values sourced from the `HKWorkoutActivityType` enum declared in
/// `HKWorkout.h` (HealthKit SDK). Unknown/future raw values fall back to
/// "Workout (<raw>)".
public enum WorkoutActivityName {
    /// Maps an `HKWorkoutActivityType.rawValue` to its human-readable name,
    /// e.g. `50` -> "Traditional Strength Training". Unknown raw values
    /// return "Workout (<raw>)".
    public static func displayName(forRawValue raw: UInt) -> String {
        switch raw {
        case 1: return "American Football"
        case 2: return "Archery"
        case 3: return "Australian Football"
        case 4: return "Badminton"
        case 5: return "Baseball"
        case 6: return "Basketball"
        case 7: return "Bowling"
        case 8: return "Boxing"
        case 9: return "Climbing"
        case 10: return "Cricket"
        case 11: return "Cross Training"
        case 12: return "Curling"
        case 13: return "Cycling"
        case 14: return "Dance"
        case 15: return "Dance Inspired Training"
        case 16: return "Elliptical"
        case 17: return "Equestrian Sports"
        case 18: return "Fencing"
        case 19: return "Fishing"
        case 20: return "Functional Strength Training"
        case 21: return "Golf"
        case 22: return "Gymnastics"
        case 23: return "Handball"
        case 24: return "Hiking"
        case 25: return "Hockey"
        case 26: return "Hunting"
        case 27: return "Lacrosse"
        case 28: return "Martial Arts"
        case 29: return "Mind And Body"
        case 30: return "Mixed Metabolic Cardio Training"
        case 31: return "Paddle Sports"
        case 32: return "Play"
        case 33: return "Preparation And Recovery"
        case 34: return "Racquetball"
        case 35: return "Rowing"
        case 36: return "Rugby"
        case 37: return "Running"
        case 38: return "Sailing"
        case 39: return "Skating Sports"
        case 40: return "Snow Sports"
        case 41: return "Soccer"
        case 42: return "Softball"
        case 43: return "Squash"
        case 44: return "Stair Climbing"
        case 45: return "Surfing Sports"
        case 46: return "Swimming"
        case 47: return "Table Tennis"
        case 48: return "Tennis"
        case 49: return "Track And Field"
        case 50: return "Traditional Strength Training"
        case 51: return "Volleyball"
        case 52: return "Walking"
        case 53: return "Water Fitness"
        case 54: return "Water Polo"
        case 55: return "Water Sports"
        case 56: return "Wrestling"
        case 57: return "Yoga"
        case 58: return "Barre"
        case 59: return "Core Training"
        case 60: return "Cross Country Skiing"
        case 61: return "Downhill Skiing"
        case 62: return "Flexibility"
        case 63: return "High Intensity Interval Training"
        case 64: return "Jump Rope"
        case 65: return "Kickboxing"
        case 66: return "Pilates"
        case 67: return "Snowboarding"
        case 68: return "Stairs"
        case 69: return "Step Training"
        case 70: return "Wheelchair Walk Pace"
        case 71: return "Wheelchair Run Pace"
        case 72: return "Tai Chi"
        case 73: return "Mixed Cardio"
        case 74: return "Hand Cycling"
        case 75: return "Disc Sports"
        case 76: return "Fitness Gaming"
        case 77: return "Cardio Dance"
        case 78: return "Social Dance"
        case 79: return "Pickleball"
        case 80: return "Cooldown"
        case 82: return "Swim Bike Run"
        case 83: return "Transition"
        case 84: return "Underwater Diving"
        case 3000: return "Other"
        default: return "Workout (\(raw))"
        }
    }

    /// Parses the stored `workout.<raw>` health-reading type string (as
    /// produced by `HealthProviders.workoutsToday`) and returns its display
    /// name. Returns nil for any type string that isn't in `workout.<raw>`
    /// form (including non-numeric suffixes).
    public static func displayName(forHealthType type: String) -> String? {
        guard type.hasPrefix("workout."),
              let raw = UInt(type.dropFirst("workout.".count)) else {
            return nil
        }
        return displayName(forRawValue: raw)
    }
}
