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

    /// Whether a multiple-choice question allows selecting more than one option.
    /// Defaults (raw nil) to true for `.multipleChoice` — today's behavior —
    /// and false for every other type.
    public var allowsMultipleSelection: Bool {
        get { allowsMultipleSelectionRaw ?? (type == .multipleChoice) }
        set { allowsMultipleSelectionRaw = newValue }
    }
}
