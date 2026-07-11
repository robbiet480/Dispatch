import Foundation

/// The Dispatch v2 interchange format. Value structs from Models/Values.swift
/// are reused directly as payload types so model↔DTO mapping stays trivial.
public struct V2Export: Codable {
    public var schemaVersion: Int = DispatchKitInfo.schemaVersion
    /// Backup provenance (backup fix, additive-optional): when this export
    /// was produced and by which device — so a backup file found in a shared
    /// iCloud folder is attributable without opening its reports. All three
    /// are optional and decoded leniently: pre-provenance v2 files (and
    /// hand-written fixtures) import with nil, per the plan-11 contract.
    public var createdAt: Date?
    public var sourceDeviceModel: String?
    public var sourceDeviceName: String?
    public var questions: [V2Question] = []
    public var reports: [V2Report] = []
    /// Prompt groups (plan 12). Optional and omitted when nil/empty so
    /// pre-group v2 exports stay byte-identical; import tolerates absence.
    public var promptGroups: [V2PromptGroup]?
    /// Person registry (plan 22). Optional and omitted when nil/empty so
    /// pre-registry v2 exports stay byte-identical; import tolerates absence
    /// (falls back to rebuild-derived vocabulary entries).
    public var people: [V2Person]?
    public init() {}
}

public struct V2Person: Codable {
    public var uniqueIdentifier: String
    public var displayName: String
    /// Omitted from JSON when nil/empty per the plan-11 nil-omission contract.
    public var alternateNames: [String]?

    public init(uniqueIdentifier: String, displayName: String, alternateNames: [String]? = nil) {
        self.uniqueIdentifier = uniqueIdentifier
        self.displayName = displayName
        self.alternateNames = alternateNames
    }
}

public struct V2PromptGroup: Codable {
    public var uniqueIdentifier: String
    public var name: String
    public var questionIDs: [String]?
    public var scheduleKind: String
    public var scheduleHours: Int?
    public var scheduleCount: Int?
    public var scheduleDistribution: String?
    /// "HH:mm" strings for the dailyAt schedule kind.
    public var scheduledTimes: [String]?
    public var isEnabled: Bool
    public var sortOrder: Int
    /// Calendar-event match rule (plan 31, calendarEventEnd schedule kind).
    /// Omitted when nil (`.allEvents` stores all-nil fields); import
    /// tolerates absence. Unknown kind raws import intact and resolve to a
    /// never-firing schedule on this build.
    public var calendarMatchKind: String?
    public var calendarIdentifiers: [String]?
    public var calendarTitleFilter: String?

    public init(uniqueIdentifier: String, name: String, questionIDs: [String]?,
                scheduleKind: String, scheduleHours: Int? = nil, scheduleCount: Int? = nil,
                scheduleDistribution: String? = nil, scheduledTimes: [String]? = nil,
                isEnabled: Bool, sortOrder: Int, calendarMatchKind: String? = nil,
                calendarIdentifiers: [String]? = nil, calendarTitleFilter: String? = nil) {
        self.uniqueIdentifier = uniqueIdentifier
        self.name = name
        self.questionIDs = questionIDs
        self.scheduleKind = scheduleKind
        self.scheduleHours = scheduleHours
        self.scheduleCount = scheduleCount
        self.scheduleDistribution = scheduleDistribution
        self.scheduledTimes = scheduledTimes
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.calendarMatchKind = calendarMatchKind
        self.calendarIdentifiers = calendarIdentifiers
        self.calendarTitleFilter = calendarTitleFilter
    }
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
    /// Optional additions (plan 11). Omitted from JSON when nil so older
    /// exports/import flows are byte-for-byte unaffected.
    public var visualization: String?
    public var defaultAnswerString: String?
    public var allowsMultipleSelection: Bool?
    /// Optional number-input-style additions (plan 21). Same nil-omission
    /// contract as the plan-11 fields above.
    public var inputStyle: String?
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputStep: Double?

    public init(uniqueIdentifier: String, prompt: String, questionType: Int,
                placeholderString: String?, choices: [String]?, sortOrder: Int,
                isEnabled: Bool, stateOfMindKind: String?, reportKinds: [ReportKind],
                visualization: String? = nil, defaultAnswerString: String? = nil,
                allowsMultipleSelection: Bool? = nil, inputStyle: String? = nil,
                inputMin: Double? = nil, inputMax: Double? = nil, inputStep: Double? = nil) {
        self.uniqueIdentifier = uniqueIdentifier
        self.prompt = prompt
        self.questionType = questionType
        self.placeholderString = placeholderString
        self.choices = choices
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.stateOfMindKind = stateOfMindKind
        self.reportKinds = reportKinds
        self.visualization = visualization
        self.defaultAnswerString = defaultAnswerString
        self.allowsMultipleSelection = allowsMultipleSelection
        self.inputStyle = inputStyle
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.inputStep = inputStep
    }
}

public struct V2Report: Codable {
    public var uniqueIdentifier: String
    public var date: Date
    public var timeZone: String
    public var kind: ReportKind
    public var trigger: ReportTrigger
    public var legacyImpetus: Int?
    public var legacySectionIdentifier: String?
    public var isBackdated: Bool
    public var isDraft: Bool
    public var wasInBackground: Bool
    public var battery: Double?
    public var altitudeMeters: Double?
    /// Location-fix-derived motion sensors (plan 43, #61).
    public var speedMPS: Double?
    public var courseDegrees: Double?
    /// Magnetometer-derived compass heading (plan 43, #61), iPhone-only capture.
    public var headingDegrees: Double?
    public var connection: Int?
    public var audio: AudioSample?
    public var location: LocationSnapshot?
    public var weather: WeatherObservation?
    public var photos: [PhotoRecord]?
    public var health: [HealthReading]?
    public var focus: FocusState?
    /// What was audibly playing at report time (plan 26). Omitted when nil;
    /// import tolerates absence.
    public var media: MediaSample?
    public var stateOfMindSampleIDs: [String]?
    public var responses: [V2Response]?
    /// The PromptGroup this report was filed against (plan 12). Omitted when
    /// nil; import tolerates absence.
    public var promptGroupID: String?
    /// Device provenance (plan 19, additive-optional): encoded when present,
    /// decoded leniently — pre-provenance v2 files import with nil.
    public var sourceDeviceModel: String?
    public var sourceDeviceName: String?

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
    public var questionIdentifier: String?
    public var tokens: [TokenValue]?
    public var answeredOptions: [String]?
    public var locationResponse: LocationAnswer?
    public var numericResponse: String?
    public var textResponses: [TokenValue]?
    /// Wall-clock time answer (plan 28). Omitted when nil; import tolerates
    /// absence (older v2 files) by yielding nil.
    public var timeResponse: TimeAnswer?

    public init(uniqueIdentifier: String, questionPrompt: String) {
        self.uniqueIdentifier = uniqueIdentifier
        self.questionPrompt = questionPrompt
    }
}

/// ISO8601 formatters for the v2 wire format. `ISO8601DateFormatter` is not
/// `Sendable`, so these are constructed fresh per use rather than shared globals.
private enum V2DateFormat {
    /// Fractional seconds — the canonical v2 wire format.
    static func fractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// No fractional seconds — accepted on decode for older v2 files.
    static func plain() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

public extension JSONEncoder {
    static var v2: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(V2DateFormat.fractional().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var v2: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = V2DateFormat.fractional().date(from: string) {
                return date
            }
            if let date = V2DateFormat.plain().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected ISO8601 date string, got \(string)")
        }
        return decoder
    }
}
