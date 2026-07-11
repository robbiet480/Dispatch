import Foundation

/// Display strings and input-config helpers shared by the iOS and macOS
/// editors (plan 47). These lived as private extensions inside the iOS view
/// files (`QuestionEditorView`, `QuestionSettingsView`, `PromptGroupsView`);
/// moving them into the kit gives both app targets one definition instead of
/// drifting twins, and makes them unit-testable. Pure, Foundation-only.

extension QuestionType {
    public var displayName: String {
        switch self {
        case .tokens: "Tokens"
        case .multipleChoice: "Multiple Choice"
        case .yesNo: "Yes/No"
        case .location: "Location"
        case .people: "People"
        case .number: "Number"
        case .note: "Note"
        case .time: "Time"
        }
    }
}

extension ReportKind {
    public var displayName: String {
        switch self {
        case .regular: "Regular"
        case .wake: "Wake"
        case .sleep: "Sleep"
        }
    }
}

extension NumberInputStyle {
    public var displayName: String {
        switch self {
        case .textField: "Text Field"
        case .slider: "Slider"
        case .stepper: "Stepper"
        case .dial: "Dial"
        case .tapCounter: "Tap Counter"
        case .scale: "Rating Scale"
        }
    }

    /// Which config fields the style exposes (spec §Styles): slider/dial/
    /// stepper take min/max/step, tapCounter an optional max, scale its
    /// min/max point range, textField nothing. Shared by the question editor
    /// and the catalog submit form (plan 41) so the exposure table has one
    /// definition (issue #58).
    public var exposedConfigFields: (min: Bool, max: Bool, step: Bool) {
        switch self {
        case .textField: (min: false, max: false, step: false)
        case .slider, .stepper, .dial: (min: true, max: true, step: true)
        case .tapCounter: (min: false, max: true, step: false)
        case .scale: (min: true, max: true, step: false)
        }
    }

    /// Parses a config text field to a FINITE Double, or nil (same rule as
    /// the default answer — junk text or "inf"/"nan" must not persist).
    public static func parseConfigText(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

extension GroupSchedule {
    /// One-line schedule readout for the groups list.
    public var summary: String {
        switch self {
        case .everyNHours(let hours):
            "Every \(hours)h"
        case .timesPerDay(let count, _):
            "\(count)× per day"
        case .dailyAt(let times):
            times.isEmpty
                ? "Daily"
                : "Daily at " + times.map(PromptGroup.timeString(fromComponents:)).joined(separator: ", ")
        case .workoutEnd:
            "When a workout ends"
        case .visitArrival:
            "When I arrive somewhere"
        case .calendarEventEnd:
            "When a calendar event ends"
        case .disabled:
            "Unknown schedule"
        }
    }
}
