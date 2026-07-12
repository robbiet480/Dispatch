import Foundation

/// Report-DETAIL rows for the capture-time context metadata (plan 44, #61) —
/// pure formatting shared by the App and Mac detail views so their sensor
/// sections stay in lockstep. Nil fields produce no row: only what was
/// captured renders. These rows appear ONLY when viewing an existing report;
/// the capture checklist never shows them.
public enum ContextMetadataDetail {
    public struct Row: Equatable, Sendable {
        /// SF Symbol name (shared across App/Mac).
        public let icon: String
        public let label: String
        public let value: String
        public init(icon: String, label: String, value: String) {
            self.icon = icon
            self.label = label
            self.value = value
        }
    }

    /// The CLLocation extras riding the location payload — rendered with the
    /// location-derived rows (right after Altitude).
    public static func locationRows(_ snapshot: LocationSnapshot?) -> [Row] {
        guard let snapshot else { return [] }
        var rows: [Row] = []
        // Every captured field renders — accuracies fold into their value's
        // row as a "(±…)" suffix rather than spawning rows of their own.
        if let mps = snapshot.speed {
            var value = String(format: "%.0f mph", MotionFormatting.mph(fromMPS: mps))
            if let accuracy = snapshot.speedAccuracy {
                value += String(format: " (±%.0f mph)", MotionFormatting.mph(fromMPS: accuracy))
            }
            rows.append(Row(icon: "speedometer", label: "Speed", value: value))
        }
        if let degrees = snapshot.course {
            rows.append(Row(icon: "location.north.line.fill", label: "Course",
                            value: degreesValue(degrees, accuracy: snapshot.courseAccuracy)))
        }
        // Prefer true (geographic) heading; fall back to magnetic — labeled,
        // so the two heading flavors stay distinguishable — when declination
        // was unavailable at capture.
        if let degrees = snapshot.trueHeading {
            rows.append(Row(icon: "location.north.circle.fill", label: "Heading",
                            value: degreesValue(degrees, accuracy: snapshot.headingAccuracy)))
        } else if let degrees = snapshot.magneticHeading {
            rows.append(Row(icon: "location.north.circle.fill", label: "Heading",
                            value: degreesValue(degrees, accuracy: snapshot.headingAccuracy)
                                + " magnetic"))
        }
        if let floor = snapshot.floorLevel {
            rows.append(Row(icon: "building", label: "Floor", value: String(floor)))
        }
        if let accuracy = snapshot.horizontalAccuracy {
            var value = String(format: "±%.0f m", accuracy)
            if let vertical = snapshot.verticalAccuracy {
                value += String(format: " · ±%.0f m vertical", vertical)
            }
            rows.append(Row(icon: "scope", label: "Accuracy", value: value))
        } else if let vertical = snapshot.verticalAccuracy {
            rows.append(Row(icon: "scope", label: "Accuracy",
                            value: String(format: "±%.0f m vertical", vertical)))
        }
        // Source flags surface only when noteworthy (true) — a normal GPS fix
        // stays quiet.
        if snapshot.isSimulatedBySoftware == true {
            rows.append(Row(icon: "exclamationmark.triangle", label: "Location source",
                            value: "Simulated"))
        }
        if snapshot.isProducedByAccessory == true {
            rows.append(Row(icon: "cable.connector", label: "Location source",
                            value: "External accessory"))
        }
        return rows
    }

    /// The device/motion context rows — rendered as the trailing group of the
    /// sensors section.
    public static func contextRows(for report: Report) -> [Row] {
        var rows: [Row] = []
        if let activity = report.motionActivity {
            rows.append(Row(icon: "figure.walk.motion", label: "Activity",
                            value: activity.capitalized))
        }
        if let kPa = report.barometricPressureKPa {
            rows.append(Row(icon: "barometer", label: "Pressure",
                            value: String(format: "%.1f kPa", kPa)))
        }
        if let lowPower = report.isLowPowerMode {
            rows.append(Row(icon: "battery.25percent", label: "Low Power Mode",
                            value: lowPower ? "On" : "Off"))
        }
        if let brightness = report.screenBrightness {
            rows.append(Row(icon: "sun.max", label: "Brightness",
                            value: String(format: "%.0f%%", brightness * 100)))
        }
        if let style = report.interfaceStyle {
            rows.append(Row(icon: "circle.lefthalf.filled", label: "Appearance",
                            value: style.capitalized))
        }
        if let route = report.audioOutputRoute {
            rows.append(Row(icon: "hifispeaker", label: "Audio Output", value: route))
        }
        return rows
    }

    private static func degreesValue(_ degrees: Double, accuracy: Double? = nil) -> String {
        // Modulo after rounding so 359.6 renders as 0°, never 360° (compass
        // degrees are 0..<360) — Copilot review catch on PR #72.
        let rounded = Int(degrees.rounded()) % 360
        var value = "\(rounded)° \(MotionFormatting.compassPoint(forDegrees: degrees))"
        if let accuracy {
            value += String(format: " (±%.0f°)", accuracy)
        }
        return value
    }
}
