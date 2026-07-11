import Foundation

/// Pure conversions for the speed/course/heading sensors (plan 43, #61).
/// CoreLocation reports `-1` for `CLLocation.speed`/`.course` when the fix
/// can't support a valid reading (stationary, poor accuracy, no course
/// estimate) — these helpers degrade that sentinel to `nil` rather than
/// surfacing a nonsensical negative value, matching the "degrade through
/// absence, not zero" pattern used elsewhere (see plan 26's MediaSample).
public enum MotionFormatting {
    /// `nil` when CoreLocation's raw speed reading is invalid (negative).
    public static func validSpeed(_ metersPerSecond: Double) -> Double? {
        metersPerSecond >= 0 ? metersPerSecond : nil
    }

    /// `nil` when CoreLocation's raw course reading is invalid (negative).
    public static func validCourse(_ degrees: Double) -> Double? {
        degrees >= 0 ? degrees : nil
    }

    /// Meters/second → miles/hour (1 m/s = 2.2369362920544... mph).
    public static func mph(fromMPS metersPerSecond: Double) -> Double {
        metersPerSecond * 2.2369362920544
    }

    /// 16-point compass abbreviation for a 0..<360 degree heading/course.
    /// Wraps correctly at the boundary (e.g. 348.75...360 → "N").
    public static func compassPoint(forDegrees degrees: Double) -> String {
        let points = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
        ]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let index = Int((positive / 22.5).rounded()) % points.count
        return points[index]
    }
}
