import Foundation
import SwiftData

/// Per-question home-visualization style override. `nil` on the question means
/// automatic-by-type (today's behavior). Named `VisualizationStyle` rather than
/// `QuestionVisualization` because that name is already taken by the aggregation
/// result enum in Visualization/VisualizationData.swift.
public enum VisualizationStyle: String, Codable, CaseIterable, Sendable {
    case proportion
    case graph
    case frequency

    /// Whether this style can render the given question type's answers.
    public func isCompatible(with type: QuestionType) -> Bool {
        switch self {
        case .proportion: type == .yesNo || type == .multipleChoice
        case .graph: type == .number
        case .frequency: type == .tokens || type == .people
        }
    }

    /// The styles that make sense for a question type (empty when the type has
    /// no selectable style, e.g. location/note).
    public static func compatibleStyles(for type: QuestionType) -> [VisualizationStyle] {
        allCases.filter { $0.isCompatible(with: type) }
    }
}

/// Number-question input control style (plan 21). Raw nil on the question
/// means the plain text field (today's behavior); unknown raw values also
/// resolve to `.textField` for forward compatibility.
public enum NumberInputStyle: String, Codable, CaseIterable, Sendable {
    case textField
    case slider
    case stepper
    case dial
    case tapCounter
    case scale

    /// Per-style config defaults (spec §Styles table). "No max" for
    /// stepper/tapCounter is represented as `.greatestFiniteMagnitude`.
    public var defaults: (min: Double, max: Double, step: Double) {
        switch self {
        case .textField, .slider, .dial: (min: 0, max: 10, step: 1)
        case .stepper, .tapCounter: (min: 0, max: .greatestFiniteMagnitude, step: 1)
        case .scale: (min: 1, max: 5, step: 1)
        }
    }

    /// Resolves stored (optional) config against the style's defaults.
    /// Non-finite stored values are ignored field-by-field; if the merged
    /// combo is still invalid (min ≥ max or step ≤ 0) the whole config
    /// clamps back to the style defaults — survey controls can always trust
    /// the returned tuple.
    public static func resolvedConfig(for style: NumberInputStyle,
                                      min: Double?, max: Double?,
                                      step: Double?) -> (min: Double, max: Double, step: Double) {
        let defaults = style.defaults
        let resolvedMin = min.flatMap { $0.isFinite ? $0 : nil } ?? defaults.min
        let resolvedMax = max.flatMap { $0.isFinite ? $0 : nil } ?? defaults.max
        let resolvedStep = step.flatMap { $0.isFinite ? $0 : nil } ?? defaults.step
        guard resolvedMin < resolvedMax, resolvedStep > 0 else { return defaults }
        return (min: resolvedMin, max: resolvedMax, step: resolvedStep)
    }
}

@Model
public final class Question {
    public var uniqueIdentifier: String = UUID().uuidString
    public var prompt: String = ""
    public var typeRaw: Int = QuestionType.tokens.rawValue
    public var placeholderString: String?
    public var choices: [String] = []
    public var sortOrder: Int = 0
    public var isEnabled: Bool = true
    /// Present ⇒ answers write HKStateOfMind samples (mapping key, e.g. "anxiety").
    public var stateOfMindKind: String?
    public var reportKindsRaw: [String] = [ReportKind.regular.rawValue]
    /// nil = automatic visualization by question type. Values: "proportion", "graph", "frequency".
    public var visualizationRaw: String?
    /// Number questions: value filed when the user leaves the answer empty. nil = file `.skipped`.
    public var defaultAnswerString: String?
    /// nil preserves pre-flag behavior: multi-select ON for `.multipleChoice`, single otherwise.
    public var allowsMultipleSelectionRaw: Bool?
    /// Number questions: input control style (plan 21). nil = plain text
    /// field. Values: "slider", "stepper", "dial", "tapCounter", "scale".
    public var inputStyleRaw: String?
    /// Number questions: per-style input config (plan 21). nil = the style's
    /// defaults (see `NumberInputStyle.resolvedConfig`).
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputStep: Double?

    public init() {}

    public var type: QuestionType {
        get { QuestionType(rawValue: typeRaw) ?? .tokens }
        set { typeRaw = newValue.rawValue }
    }

    public var reportKinds: [ReportKind] {
        get { reportKindsRaw.compactMap(ReportKind.init(rawValue:)) }
        set { reportKindsRaw = newValue.map(\.rawValue) }
    }

    /// Home-visualization style override; nil (or an unknown raw value) means
    /// automatic-by-type.
    public var visualization: VisualizationStyle? {
        get { visualizationRaw.flatMap(VisualizationStyle.init(rawValue:)) }
        set { visualizationRaw = newValue?.rawValue }
    }

    /// Number-question input control style; raw nil OR an unknown raw value
    /// resolves to the plain text field. Setting `.textField` writes raw nil
    /// so default-styled questions stay byte-identical in exports.
    public var inputStyle: NumberInputStyle {
        get { inputStyleRaw.flatMap(NumberInputStyle.init(rawValue:)) ?? .textField }
        set { inputStyleRaw = newValue == .textField ? nil : newValue.rawValue }
    }

    /// Whether a multiple-choice question allows selecting more than one option.
    /// Defaults (raw nil) to true for `.multipleChoice` — today's behavior —
    /// and false for every other type.
    public var allowsMultipleSelection: Bool {
        get { allowsMultipleSelectionRaw ?? (type == .multipleChoice) }
        set { allowsMultipleSelectionRaw = newValue }
    }
}
