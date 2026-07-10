import Foundation
import SwiftData

@Model
public final class Response {
    public var uniqueIdentifier: String = UUID().uuidString
    /// Join key to Question.prompt — matches the original app's export semantics.
    public var questionPrompt: String = ""
    /// Stable join to `Question.uniqueIdentifier`, surviving prompt edits. Populated
    /// on v1 import via a prompt→identifier lookup built from the export's questions;
    /// left nil when no match is found. Prefer this over `questionPrompt` when present.
    public var questionIdentifier: String?
    /// Token/people answers (questions of type `.tokens` or `.people`).
    public var tokens: [TokenValue]?
    public var answeredOptions: [String]?
    public var locationResponse: LocationAnswer?
    public var numericResponse: String?
    /// Wall-clock time-of-day answer (questions of type `.time`, plan 28)
    /// stored as raw scalars, NOT a composite `TimeAnswer`. SwiftData's
    /// composite-value storage SIGTRAPs on TimeAnswer's renamed CodingKey
    /// (`minutesSinceMidnight` → "minutes") plus its conditional `dayOffset`
    /// encode — the same trap documented for MediaSample in Values.swift.
    /// `timeMinutes == nil` means "no time answer"; the typed `timeResponse`
    /// accessor rebuilds the struct. The JSON wire format is untouched:
    /// V2Response still carries a real `TimeAnswer` with its custom Codable.
    public var timeMinutes: Int?
    public var timeDayOffset: Int = 0

    public var timeResponse: TimeAnswer? {
        get {
            guard let timeMinutes else { return nil }
            return TimeAnswer(minutesSinceMidnight: timeMinutes, dayOffset: timeDayOffset)
        }
        set {
            timeMinutes = newValue?.minutesSinceMidnight
            timeDayOffset = newValue?.dayOffset ?? 0
        }
    }
    /// Free-text note answers (questions of type `.note`), distinct from `tokens`.
    public var textResponses: [TokenValue]?
    public var report: Report?

    public init() {}
}
