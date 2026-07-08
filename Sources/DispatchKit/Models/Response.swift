import Foundation
import SwiftData

@Model
public final class Response {
    public var uniqueIdentifier: String = UUID().uuidString
    /// Join key to Question.prompt — matches the original app's export semantics.
    public var questionPrompt: String = ""
    public var tokens: [TokenValue]?
    public var answeredOptions: [String]?
    public var locationResponse: LocationAnswer?
    public var numericResponse: String?
    public var textResponses: [TokenValue]?
    public var report: Report?

    public init() {}
}
