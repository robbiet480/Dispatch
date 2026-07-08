import Foundation

/// The Dispatch v2 interchange format. Value structs from Models/Values.swift
/// are reused directly as payload types so model↔DTO mapping stays trivial.
public struct V2Export: Codable {
    public var schemaVersion: Int = DispatchKitInfo.schemaVersion
    public var questions: [V2Question] = []
    public var reports: [V2Report] = []
    public init() {}
}

public struct V2Question: Codable {
    public var uniqueIdentifier: String
    public var prompt: String
    public var questionType: Int
    public var placeholderString: String?
    public var choices: [String]?
    public var sortOrder: Int
    public var isEnabled: Bool
    public var stateOfMindKind: String?
    public var reportKinds: [ReportKind]

    public init(uniqueIdentifier: String, prompt: String, questionType: Int,
                placeholderString: String?, choices: [String]?, sortOrder: Int,
                isEnabled: Bool, stateOfMindKind: String?, reportKinds: [ReportKind]) {
        self.uniqueIdentifier = uniqueIdentifier
        self.prompt = prompt
        self.questionType = questionType
        self.placeholderString = placeholderString
        self.choices = choices
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.stateOfMindKind = stateOfMindKind
        self.reportKinds = reportKinds
    }
}

public struct V2Report: Codable {
    public var uniqueIdentifier: String
    public var date: Date
    public var timeZone: String
    public var kind: ReportKind
    public var trigger: ReportTrigger
    public var legacyImpetus: Int?
    public var isBackdated: Bool
    public var isDraft: Bool
    public var wasInBackground: Bool
    public var battery: Double?
    public var altitudeMeters: Double?
    public var connection: Int?
    public var audio: AudioSample?
    public var location: LocationSnapshot?
    public var weather: WeatherObservation?
    public var photos: [PhotoRecord]?
    public var health: [HealthReading]?
    public var focus: FocusState?
    public var stateOfMindSampleIDs: [String]?
    public var responses: [V2Response]?

    public init(uniqueIdentifier: String, date: Date, timeZone: String,
                kind: ReportKind, trigger: ReportTrigger) {
        self.uniqueIdentifier = uniqueIdentifier
        self.date = date
        self.timeZone = timeZone
        self.kind = kind
        self.trigger = trigger
        self.isBackdated = false
        self.isDraft = false
        self.wasInBackground = false
    }
}

public struct V2Response: Codable {
    public var uniqueIdentifier: String
    public var questionPrompt: String
    public var tokens: [TokenValue]?
    public var answeredOptions: [String]?
    public var locationResponse: LocationAnswer?
    public var numericResponse: String?
    public var textResponses: [TokenValue]?

    public init(uniqueIdentifier: String, questionPrompt: String) {
        self.uniqueIdentifier = uniqueIdentifier
        self.questionPrompt = questionPrompt
    }
}

public extension JSONEncoder {
    static var v2: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var v2: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
