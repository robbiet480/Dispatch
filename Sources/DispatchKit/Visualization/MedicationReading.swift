import Foundation

/// Pure mapping for medication dose events stored as additive HealthReadings
/// (plan 14 T5). Type string: `medication.<status>.<name>` where status is
/// "taken"/"skipped" and name is the user-facing medication name (nickname
/// when set, else the concept display text — may itself contain dots, so
/// parsing splits on the FIRST dot after the status only). No HealthKit
/// import — DispatchKit stays a data/logic layer.
public enum MedicationReading {
    public static let prefix = "medication."

    public struct Parsed: Equatable, Sendable {
        public let status: String
        public let name: String
        public init(status: String, name: String) {
            self.status = status
            self.name = name
        }
    }

    public static func type(status: String, name: String) -> String {
        "\(prefix)\(status).\(name)"
    }

    /// nil for non-medication readings (including the pre-plan-14
    /// placeholder type "medicationDose", which carried no name).
    public static func parse(_ type: String) -> Parsed? {
        guard type.hasPrefix(prefix) else { return nil }
        let rest = type.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let status = String(rest[..<dot])
        let name = String(rest[rest.index(after: dot)...])
        guard !status.isEmpty, !name.isEmpty else { return nil }
        return Parsed(status: status, name: name)
    }

    /// Detail-row line: "Ibuprofen · 1 tablet · taken". Values render with %g
    /// (no trailing .0); a "count" unit is dropped as noise.
    public static func detailLine(type: String, value: Double, unit: String) -> String? {
        guard let parsed = parse(type) else { return nil }
        let quantity = unit == "count" || unit.isEmpty
            ? String(format: "%g", value)
            : "\(String(format: "%g", value)) \(unit)"
        return "\(parsed.name) · \(quantity) · \(parsed.status)"
    }
}
