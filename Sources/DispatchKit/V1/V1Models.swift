import Foundation

/// Question types shared across v1 import, v2 schema, and the SwiftData models.
/// Raw values verified against the original Reporter export.
public enum QuestionType: Int, Codable, Sendable, CaseIterable {
    case tokens = 0
    case multipleChoice = 1
    case yesNo = 2
    case location = 3
    case people = 4
    case number = 5
    case note = 6
    /// 7+ are additive (plan 28) — NEVER renumber existing raws.
    case time = 7
}

/// Wraps a decodable element to capture failures on a per-record basis.
/// If decoding fails, value is nil; the container itself doesn't throw.
struct FailableElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Decode-only DTOs mirroring the original Reporter `reporter-export.json`.
public struct V1Export: Decodable {
    public var questions: [V1Question]
    public var snapshots: [V1Snapshot]
    public var decodeFailures: Int = 0

    enum CodingKeys: String, CodingKey {
        case questions, snapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let questionsContainer = try container.decode([FailableElement<V1Question>].self, forKey: .questions)
        let snapshotsContainer = try container.decode([FailableElement<V1Snapshot>].self, forKey: .snapshots)

        questions = questionsContainer.compactMap { $0.value }
        snapshots = snapshotsContainer.compactMap { $0.value }
        decodeFailures = (questionsContainer.count - questions.count) + (snapshotsContainer.count - snapshots.count)
    }

    public static func decode(from data: Data) throws -> V1Export {
        try JSONDecoder().decode(V1Export.self, from: data)
    }
}

public struct V1Question: Decodable {
    public var questionType: Int
    public var prompt: String
    public var uniqueIdentifier: String
    public var placeholderString: String?
}

/// v1 dates appear as ISO-ish strings in modern exports and as Doubles
/// (seconds since 2001-01-01 GMT) in legacy ones. Accept both.
public enum V1DateValue: Decodable {
    case string(String)
    case reference(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .reference(try container.decode(Double.self))
        }
    }

    /// Legacy numeric dates carry no offset; treat them as GMT.
    public var resolved: (date: Date, utcOffsetSeconds: Int)? {
        switch self {
        case .string(let string): return V1DateParser.parse(string)
        case .reference(let seconds): return (Date(timeIntervalSinceReferenceDate: seconds), 0)
        }
    }
}

/// v1 altitude can be a simple double (test fixture) or an altitude object (real export).
public enum V1AltitudeValue: Decodable {
    case simple(Double)
    case detailed(V1AltitudeData)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            self = .simple(double)
        } else {
            self = .detailed(try container.decode(V1AltitudeData.self))
        }
    }
}

public struct V1AltitudeData: Decodable {
    public var floorsAscended: Int?
    public var floorsDescended: Int?
    public var gpsAltitudeFromLocation: Double?
    public var gpsRawAltitude: Double?
    public var pressure: Double?
    public var adjustedPressure: Double?
}

public struct V1Snapshot: Decodable {
    public var uniqueIdentifier: String
    public var date: V1DateValue
    public var sectionIdentifier: String?
    public var battery: Double?
    public var steps: Int?
    public var altitude: V1AltitudeValue?
    public var background: Int?
    public var draft: Int?
    public var connection: Int?
    public var reportImpetus: Int?
    public var audio: V1Audio?
    public var location: V1Location?
    public var weather: V1Weather?
    public var photoSet: V1PhotoSet?
    public var responses: [V1Response]?
}

public struct V1Audio: Decodable {
    public var avg: Double
    public var peak: Double
}

public struct V1Location: Decodable {
    public var latitude: Double
    public var longitude: Double
    public var speed: Double?
    public var course: Double?
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    public var timestamp: V1DateValue?
    public var placemark: V1Placemark?
}

public struct V1Placemark: Decodable {
    public var name: String?
    public var thoroughfare: String?
    public var subThoroughfare: String?
    public var locality: String?
    public var subLocality: String?
    public var administrativeArea: String?
    public var subAdministrativeArea: String?
    public var postalCode: String?
    public var country: String?
    public var region: String?
}

public struct V1Weather: Decodable {
    public var tempF: Double?
    public var tempC: Double?
    public var weather: String?
    public var relativeHumidity: String?
    public var windMPH: Double?
    public var windKPH: Double?
    public var windGustMPH: Double?
    public var windGustKPH: Double?
    public var windDirection: String?
    public var windDegrees: Double?
    public var pressureIn: Double?
    public var pressureMb: Double?
    public var visibilityMi: Double?
    public var visibilityKM: Double?
    public var feelslikeF: Double?
    public var feelslikeC: Double?
    public var dewpointC: Double?
    public var precipTodayIn: Double?
    public var precipTodayMetric: Double?
    public var uv: Double?
    public var stationID: String?
    public var latitude: Double?
    public var longitude: Double?
}

public struct V1PhotoSet: Decodable {
    public var photos: [V1Photo]
}

public struct V1Photo: Decodable {
    public var uniqueIdentifier: String
    public var assetUrl: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var dateTime: V1DateValue?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
}

public struct V1Response: Decodable {
    public var questionPrompt: String
    public var uniqueIdentifier: String
    public var tokens: [V1Token]?
    public var answeredOptions: [String]?
    public var locationResponse: V1LocationResponse?
    public var numericResponse: String?
    public var textResponses: [V1Token]?

    enum CodingKeys: String, CodingKey {
        case questionPrompt, uniqueIdentifier, tokens, answeredOptions
        case locationResponse, numericResponse, textResponses, textResponse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questionPrompt = try container.decode(String.self, forKey: .questionPrompt)
        uniqueIdentifier = try container.decode(String.self, forKey: .uniqueIdentifier)
        tokens = try container.decodeIfPresent([V1Token].self, forKey: .tokens)
        answeredOptions = try container.decodeIfPresent([String].self, forKey: .answeredOptions)
        locationResponse = try container.decodeIfPresent(V1LocationResponse.self, forKey: .locationResponse)
        numericResponse = try container.decodeIfPresent(String.self, forKey: .numericResponse)
        // Modern exports: textResponses [{id, text}]. Legacy: textResponse "…".
        if let modern = try container.decodeIfPresent([V1Token].self, forKey: .textResponses) {
            textResponses = modern
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .textResponse) {
            textResponses = [V1Token(uniqueIdentifier: UUID().uuidString, text: legacy)]
        }
    }
}

/// Modern exports encode tokens as {uniqueIdentifier, text}; legacy ones as
/// bare strings. Accept both.
public struct V1Token: Decodable {
    public var uniqueIdentifier: String
    public var text: String

    enum CodingKeys: String, CodingKey { case uniqueIdentifier, text }

    init(uniqueIdentifier: String, text: String) {
        self.uniqueIdentifier = uniqueIdentifier
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            self.init(uniqueIdentifier: UUID().uuidString, text: bare)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(uniqueIdentifier: try container.decode(String.self, forKey: .uniqueIdentifier),
                  text: try container.decode(String.self, forKey: .text))
    }
}

public struct V1LocationResponse: Decodable {
    public var text: String?
    public var foursquareVenueId: String?
    public var location: V1Location?
}
