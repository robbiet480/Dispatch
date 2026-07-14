import Foundation

/// Non-interactive rendering of a question's input control, resolved off the
/// data model with no SwiftUI dependency so it is unit-testable and shareable.
/// The SwiftUI renderer (`QuestionInputPreviewView`) switches on this.
public enum QuestionPreviewControl: Equatable, Sendable {
    case number(NumberPreview)
    case choices(options: [String], multiSelect: Bool, selected: Int?)
    case yesNo(selected: Bool?)
    case tokens(samples: [String])
    case people(sample: String)
    case location
    case note(placeholder: String?)
    case time(sample: String)

    public enum NumberPreview: Equatable, Sendable {
        case textField(placeholder: String?, value: String?)
        case slider(min: Double, max: Double, value: Double)
        case stepper(value: Double)
        case dial(min: Double, max: Double, value: Double)
        case tapCounter(value: Int)
        case scale(points: [Int], selected: Int)
    }
}

public enum QuestionInputPreview {
    /// A representative value inside [min, max]: the midpoint, rounded to the
    /// nearest step, clamped in-range. Used for slider/dial previews.
    private static func midValue(min: Double, max: Double, step: Double) -> Double {
        let mid = (min + max) / 2
        guard step > 0 else { return mid }
        let snapped = (mid / step).rounded() * step
        return Swift.min(Swift.max(snapped, min), max)
    }

    /// A representative count for unbounded styles (stepper/tapCounter):
    /// clamp a friendly sample of 3 into [min, max] when those are finite.
    private static func sampleCount(min: Double, max: Double) -> Double {
        let sample = 3.0
        let lo = min.isFinite ? min : sample
        let hi = max.isFinite ? max : sample
        return Swift.min(Swift.max(sample, lo), Swift.max(lo, hi))
    }

    public static func control(
        forType type: QuestionType,
        inputStyle: NumberInputStyle,
        choices: [String],
        allowsMultipleSelection: Bool,
        inputMin: Double?, inputMax: Double?, inputStep: Double?,
        placeholder: String?,
        defaultAnswer: String?
    ) -> QuestionPreviewControl {
        switch type {
        case .number:
            let cfg = NumberInputStyle.resolvedConfig(for: inputStyle, min: inputMin, max: inputMax, step: inputStep)
            switch inputStyle {
            case .textField:
                return .number(.textField(
                    placeholder: placeholder?.isEmpty == false ? placeholder : nil,
                    value: defaultAnswer?.isEmpty == false ? defaultAnswer : nil))
            case .slider:
                return .number(.slider(min: cfg.min, max: cfg.max, value: midValue(min: cfg.min, max: cfg.max, step: cfg.step)))
            case .dial:
                return .number(.dial(min: cfg.min, max: cfg.max, value: midValue(min: cfg.min, max: cfg.max, step: cfg.step)))
            case .stepper:
                return .number(.stepper(value: sampleCount(min: cfg.min, max: cfg.max)))
            case .tapCounter:
                // `Int(hugeDouble)` traps — a poison-pill catalog entry with an
                // extreme bound (e.g. min = 1e20) would otherwise crash the
                // preview. Clamp into Int's representable range first, then cast
                // via `Int(exactly:)`: `Double(Int.max)` rounds up to 2^63 (one
                // past Int.max), so the exact boundary still needs the fallback.
                let sample = sampleCount(min: cfg.min, max: cfg.max)
                let safeSample = Swift.min(Swift.max(sample, Double(Int.min)), Double(Int.max))
                let value = Int(exactly: safeSample.rounded(.towardZero)) ?? Int.max
                return .number(.tapCounter(value: value))
            case .scale:
                let points = NumberInputStyle.scalePoints(min: cfg.min, max: cfg.max)
                let selected = points.isEmpty ? 0 : points[points.count / 2]
                return .number(.scale(points: points, selected: selected))
            }
        case .multipleChoice:
            return .choices(options: choices, multiSelect: allowsMultipleSelection, selected: choices.isEmpty ? nil : 0)
        case .yesNo:
            return .yesNo(selected: nil)
        case .tokens:
            return .tokens(samples: ["work", "home", "focus"])
        case .people:
            return .people(sample: "Alex")
        case .location:
            return .location
        case .note:
            return .note(placeholder: placeholder?.isEmpty == false ? placeholder : nil)
        case .time:
            return .time(sample: "3:30 PM")
        }
    }

    public static func control(for entry: CatalogQuestion) -> QuestionPreviewControl {
        let style = entry.inputStyle.flatMap(NumberInputStyle.init(rawValue:)) ?? .textField
        return control(
            forType: entry.type ?? .note, inputStyle: style, choices: entry.choices,
            allowsMultipleSelection: entry.type == .multipleChoice,
            inputMin: entry.inputMin, inputMax: entry.inputMax, inputStep: entry.inputStep,
            placeholder: entry.placeholder, defaultAnswer: entry.defaultAnswer)
    }

    public static func control(for question: Question) -> QuestionPreviewControl {
        control(
            forType: question.type, inputStyle: question.inputStyle, choices: question.choices,
            allowsMultipleSelection: question.allowsMultipleSelection,
            inputMin: question.inputMin, inputMax: question.inputMax, inputStep: question.inputStep,
            placeholder: question.placeholderString, defaultAnswer: question.defaultAnswerString)
    }
}
