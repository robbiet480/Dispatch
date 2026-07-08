import Foundation
import SwiftData

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

    public init() {}

    public var type: QuestionType {
        get { QuestionType(rawValue: typeRaw) ?? .tokens }
        set { typeRaw = newValue.rawValue }
    }

    public var reportKinds: [ReportKind] {
        get { reportKindsRaw.compactMap(ReportKind.init(rawValue:)) }
        set { reportKindsRaw = newValue.map(\.rawValue) }
    }
}
