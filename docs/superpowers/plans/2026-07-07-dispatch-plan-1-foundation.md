# Dispatch Plan 1: Foundation (models, codecs, import/export) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `DispatchKit` — the fully unit-tested core of Dispatch: SwiftData models, v1 (original Reporter) import, v2 export/import with round-trip fidelity, CSV export, and vocabulary derivation — plus a buildable iOS app shell.

**Architecture:** A Swift Package (`DispatchKit`) holds pure-Codable DTOs for the v1/v2 interchange formats, SwiftData `@Model` persistence classes, and mapper/importer/exporter services. Everything runs under `swift test` on macOS (in-memory ModelContainer, no CloudKit). A thin XcodeGen-generated app target (`DispatchApp`, product name "Dispatch") links the package. Later plans add UI, sensors, prompting.

**Tech Stack:** Swift 6.3, Swift Testing (`import Testing`), SwiftData, XcodeGen, iOS 26 / macOS 26 minimums.

**Spec:** `docs/superpowers/specs/2026-07-07-reporter-clone-design.md`

## Global Constraints

- Minimum deployment: **iOS 26, macOS 26** (macOS only so `swift test` runs locally/CI).
- The Swift library module is **`DispatchKit`** and the app module **`DispatchApp`** — never name a module `Dispatch` (collides with Apple's GCD module).
- Schema v2 exports carry `"schemaVersion": 2`; v1 import is one-way (original Reporter format).
- v1 question type mapping (verified against the real export): 0=tokens, 1=multipleChoice, 2=yesNo, 3=location, 4=people, 5=number, 6=note.
- v1 dates are `yyyy-MM-dd'T'HH:mm:ssZ` (colonless offset, e.g. `2016-02-11T19:08:54-0400`); per-report timezone derives from that offset.
- `numericResponse` is a **string** in both v1 and v2.
- All `@Model` stored properties must have defaults or be optional (CloudKit mirroring compatibility); no `#Unique` constraints — dedupe by `uniqueIdentifier` in code.
- Never commit `/IMG_*.PNG` or `/reporter-export.json` (already gitignored). Tests use the synthetic fixture only; the real export is referenced only via an env var for an optional local-only test.
- MIT license, original branding only ("Dispatch"), no copied Reporter assets.
- Commit after every green test cycle.

---

### Task 1: Swift Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/DispatchKit/DispatchKit.swift`
- Test: `Tests/DispatchKitTests/SmokeTests.swift`

**Interfaces:**
- Produces: the `DispatchKit` library target and test target every later task builds on.

- [ ] **Step 1: Write the package manifest and a smoke test**

`Package.swift`:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DispatchKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DispatchKit", targets: ["DispatchKit"])
    ],
    targets: [
        .target(name: "DispatchKit"),
        .testTarget(
            name: "DispatchKitTests",
            dependencies: ["DispatchKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

`Sources/DispatchKit/DispatchKit.swift`:

```swift
/// Namespace marker for the DispatchKit core library.
public enum DispatchKitInfo {
    public static let schemaVersion = 2
}
```

`Tests/DispatchKitTests/SmokeTests.swift`:

```swift
import Testing
@testable import DispatchKit

@Test func schemaVersionIsTwo() {
    #expect(DispatchKitInfo.schemaVersion == 2)
}
```

- [ ] **Step 2: Create the Fixtures directory placeholder**

Run: `mkdir -p Tests/DispatchKitTests/Fixtures && touch Tests/DispatchKitTests/Fixtures/.gitkeep`

- [ ] **Step 3: Run tests**

Run: `swift test`
Expected: `Test run with 1 test passed`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: scaffold DispatchKit Swift package"
```

---

### Task 2: v1 DTOs — decode the original Reporter export

**Files:**
- Create: `Sources/DispatchKit/V1/V1Models.swift`
- Create: `Sources/DispatchKit/V1/V1DateParser.swift`
- Create: `Tests/DispatchKitTests/Fixtures/v1-sample.json`
- Test: `Tests/DispatchKitTests/V1DecodingTests.swift`

**Interfaces:**
- Consumes: nothing (pure Codable layer).
- Produces: `V1Export` (`questions: [V1Question]`, `snapshots: [V1Snapshot]`), `V1DateParser.parse(_ s: String) -> (date: Date, utcOffsetSeconds: Int)?`, and the fixture used by every later import test. `QuestionType` enum (shared by v1/v2/models).

- [ ] **Step 1: Write the synthetic fixture**

`Tests/DispatchKitTests/Fixtures/v1-sample.json` — 7 questions (one per type) and 3 snapshots covering every response payload variant, a skipped question, photoSet, weather, and a snapshot with no location:

```json
{
  "questions": [
    {"questionType": 0, "prompt": "What are you doing?", "uniqueIdentifier": "q-tokens"},
    {"questionType": 1, "prompt": "What is your anxiety level?", "uniqueIdentifier": "q-multi"},
    {"questionType": 2, "prompt": "Are you working?", "uniqueIdentifier": "q-yesno"},
    {"questionType": 3, "prompt": "Where are you?", "uniqueIdentifier": "q-location"},
    {"questionType": 4, "prompt": "Who are you with?", "uniqueIdentifier": "q-people", "placeholderString": "No one"},
    {"questionType": 5, "prompt": "How many coffees did you have today?", "uniqueIdentifier": "q-number"},
    {"questionType": 6, "prompt": "What did you learn today?", "uniqueIdentifier": "q-note"}
  ],
  "snapshots": [
    {
      "uniqueIdentifier": "snap-1",
      "date": "2016-02-11T19:08:54-0400",
      "sectionIdentifier": "1-2016-2-11",
      "battery": 0.96,
      "steps": 481,
      "altitude": 12.5,
      "background": 0,
      "draft": 0,
      "connection": 0,
      "reportImpetus": 0,
      "audio": {"avg": -43.57, "peak": -34.0, "uniqueIdentifier": "aud-1"},
      "location": {
        "latitude": 37.8116, "longitude": -122.2642,
        "speed": -1, "course": 0, "altitude": 0,
        "horizontalAccuracy": 65, "verticalAccuracy": 10,
        "timestamp": "2016-02-11T19:08:54-0400",
        "uniqueIdentifier": "loc-1",
        "placemark": {
          "locality": "Oakland", "administrativeArea": "CA",
          "country": "United States", "postalCode": "94612",
          "thoroughfare": "Valdez St", "name": "2201–2295 Valdez St",
          "uniqueIdentifier": "pm-1"
        }
      },
      "weather": {
        "tempF": 68.7, "tempC": 20.4, "weather": "Mostly Cloudy",
        "relativeHumidity": "60%", "windMPH": 0, "windKPH": 0,
        "pressureIn": 30.12, "pressureMb": 1020, "visibilityMi": 10,
        "uv": 1, "stationID": "KCAOAKLA38", "windDirection": "East",
        "windDegrees": 84, "feelslikeF": 68.7, "feelslikeC": 20.4,
        "dewpointC": 12, "precipTodayIn": 0, "precipTodayMetric": 0,
        "windGustMPH": 4, "windGustKPH": 6.4, "visibilityKM": 16.1,
        "latitude": 37.8086, "longitude": -122.2675,
        "uniqueIdentifier": "wx-1"
      },
      "responses": [
        {"questionPrompt": "What are you doing?", "uniqueIdentifier": "r-1a",
         "tokens": [{"uniqueIdentifier": "t-1", "text": "Working"}, {"uniqueIdentifier": "t-2", "text": "Coding"}]},
        {"questionPrompt": "Are you working?", "uniqueIdentifier": "r-1b",
         "answeredOptions": ["Yes"]},
        {"questionPrompt": "What is your anxiety level?", "uniqueIdentifier": "r-1c",
         "answeredOptions": ["Low"]},
        {"questionPrompt": "How many coffees did you have today?", "uniqueIdentifier": "r-1d",
         "numericResponse": "3"}
      ]
    },
    {
      "uniqueIdentifier": "snap-2",
      "date": "2015-10-21T20:10:24-0400",
      "sectionIdentifier": "0-2015-10-21",
      "battery": 0.5,
      "steps": 12034,
      "altitude": 41.0,
      "background": 0,
      "draft": 0,
      "connection": 1,
      "reportImpetus": 2,
      "audio": {"avg": -20.1, "peak": -8.4, "uniqueIdentifier": "aud-2"},
      "location": {
        "latitude": 37.8114, "longitude": -122.2652,
        "speed": -1, "course": 0, "altitude": 0,
        "horizontalAccuracy": 30, "verticalAccuracy": -1,
        "timestamp": "2015-10-21T20:10:24-0400",
        "uniqueIdentifier": "loc-2",
        "placemark": {"locality": "Oakland", "administrativeArea": "CA", "uniqueIdentifier": "pm-2"}
      },
      "photoSet": {
        "uniqueIdentifier": "ps-2",
        "photos": [
          {"uniqueIdentifier": "ph-1", "assetUrl": "assets-library://asset/asset.PNG?id=AAA&ext=PNG",
           "pixelWidth": 1242, "pixelHeight": 2208, "dateTime": "2015-10-21T16:43:16-0400",
           "latitude": 0, "longitude": 0, "altitude": 0, "depth": 8, "resolutionUnit": 0}
        ]
      },
      "responses": [
        {"questionPrompt": "Where are you?", "uniqueIdentifier": "r-2a",
         "locationResponse": {
           "text": "The Grand", "foursquareVenueId": "4c4a6895",
           "uniqueIdentifier": "lr-1",
           "location": {"latitude": 37.8114, "longitude": -122.2652, "speed": -1, "course": 0,
                        "altitude": 0, "horizontalAccuracy": 0, "verticalAccuracy": -1,
                        "timestamp": "2015-10-21T20:10:24-0400", "uniqueIdentifier": "loc-2b"}}},
        {"questionPrompt": "What did you learn today?", "uniqueIdentifier": "r-2b",
         "textResponses": [{"uniqueIdentifier": "tr-1", "text": "SwiftData exists"}]},
        {"questionPrompt": "Who are you with?", "uniqueIdentifier": "r-2c"}
      ]
    },
    {
      "uniqueIdentifier": "snap-3",
      "date": "2017-02-28T13:08:09-0500",
      "sectionIdentifier": "0-2017-2-28",
      "battery": 0.12,
      "steps": 27851,
      "altitude": 63.0,
      "background": 0,
      "draft": 0,
      "connection": 0,
      "reportImpetus": 4,
      "audio": {"avg": -50.0, "peak": -41.2, "uniqueIdentifier": "aud-3"},
      "responses": [
        {"questionPrompt": "Who are you with?", "uniqueIdentifier": "r-3a",
         "tokens": [{"uniqueIdentifier": "t-3", "text": "Melissa"}]}
      ]
    }
  ]
}
```

- [ ] **Step 2: Write the failing decoding tests**

`Tests/DispatchKitTests/V1DecodingTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    return try Data(contentsOf: try #require(url))
}

@Test func decodesV1Fixture() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    #expect(export.questions.count == 7)
    #expect(export.snapshots.count == 3)
}

@Test func decodesQuestionTypes() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    let types = Dictionary(uniqueKeysWithValues: export.questions.map { ($0.uniqueIdentifier, $0.questionType) })
    #expect(types["q-tokens"] == QuestionType.tokens.rawValue)
    #expect(types["q-multi"] == QuestionType.multipleChoice.rawValue)
    #expect(types["q-yesno"] == QuestionType.yesNo.rawValue)
    #expect(types["q-location"] == QuestionType.location.rawValue)
    #expect(types["q-people"] == QuestionType.people.rawValue)
    #expect(types["q-number"] == QuestionType.number.rawValue)
    #expect(types["q-note"] == QuestionType.note.rawValue)
}

@Test func decodesResponseVariants() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    let snap1 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-1" })
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1a" }?.tokens?.count == 2)
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1b" }?.answeredOptions == ["Yes"])
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1d" }?.numericResponse == "3")

    let snap2 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-2" })
    #expect(snap2.responses?.first { $0.uniqueIdentifier == "r-2a" }?.locationResponse?.text == "The Grand")
    #expect(snap2.responses?.first { $0.uniqueIdentifier == "r-2b" }?.textResponses?.first?.text == "SwiftData exists")
    let skipped = try #require(snap2.responses?.first { $0.uniqueIdentifier == "r-2c" })
    #expect(skipped.tokens == nil && skipped.answeredOptions == nil && skipped.numericResponse == nil)
    #expect(snap2.photoSet?.photos.count == 1)

    let snap3 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-3" })
    #expect(snap3.location == nil && snap3.weather == nil)
}

@Test func parsesColonlessOffsetDates() throws {
    let parsed = try #require(V1DateParser.parse("2016-02-11T19:08:54-0400"))
    #expect(parsed.utcOffsetSeconds == -4 * 3600)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(cal.component(.hour, from: parsed.date) == 23) // 19:08 -0400 == 23:08 UTC
}

@Test func decodesLegacyVariants() throws {
    // Legacy exports: numeric dates (seconds since 2001-01-01 GMT),
    // bare-string tokens, singular textResponse (gist.github.com/dbreunig/9315705).
    let json = Data("""
    {"questions": [], "snapshots": [{
        "uniqueIdentifier": "legacy-1",
        "date": 415092465.0,
        "responses": [
            {"questionPrompt": "What are you doing?", "uniqueIdentifier": "lr-1", "tokens": ["Working"]},
            {"questionPrompt": "What did you learn today?", "uniqueIdentifier": "lr-2", "textResponse": "Old format"}
        ]
    }]}
    """.utf8)
    let export = try V1Export.decode(from: json)
    let snap = try #require(export.snapshots.first)
    let resolved = try #require(snap.date.resolved)
    #expect(resolved.date == Date(timeIntervalSinceReferenceDate: 415_092_465.0))
    #expect(resolved.utcOffsetSeconds == 0)
    #expect(snap.responses?.first?.tokens?.first?.text == "Working")
    #expect(snap.responses?.last?.textResponses?.first?.text == "Old format")
}

@Test func decodesRealExportIfPresent() throws {
    // Local-only: DISPATCH_V1_EXPORT=/path/to/reporter-export.json swift test
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let export = try V1Export.decode(from: try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(export.snapshots.count == 94)
    #expect(export.questions.count == 38)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'V1Export' in scope`, `cannot find 'QuestionType' in scope`

- [ ] **Step 4: Implement the DTOs and date parser**

`Sources/DispatchKit/V1/V1DateParser.swift`:

```swift
import Foundation

/// Parses the original Reporter export's date strings, e.g. "2016-02-11T19:08:54-0400".
public enum V1DateParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    public static func parse(_ string: String) -> (date: Date, utcOffsetSeconds: Int)? {
        guard let date = formatter.date(from: string) else { return nil }
        // Offset is the trailing ±HHmm.
        guard string.count >= 5 else { return nil }
        let tail = String(string.suffix(5))
        guard let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)),
              let minutes = Int(tail.suffix(2)) else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return (date, sign == "-" ? -magnitude : magnitude)
    }
}
```

`Sources/DispatchKit/V1/V1Models.swift`:

```swift
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
}

/// Decode-only DTOs mirroring the original Reporter `reporter-export.json`.
public struct V1Export: Decodable {
    public var questions: [V1Question]
    public var snapshots: [V1Snapshot]

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

public struct V1Snapshot: Decodable {
    public var uniqueIdentifier: String
    public var date: V1DateValue
    public var sectionIdentifier: String?
    public var battery: Double?
    public var steps: Int?
    public var altitude: Double?
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (6 tests; `decodesRealExportIfPresent` no-ops without the env var)

- [ ] **Step 6: Verify against the real export locally**

Run: `DISPATCH_V1_EXPORT=$PWD/reporter-export.json swift test --filter decodesRealExportIfPresent`
Expected: PASS — proves the DTOs decode all 94 real snapshots / 38 questions

- [ ] **Step 7: Commit**

```bash
git add Sources/DispatchKit/V1 Tests/DispatchKitTests
git commit -m "feat: decode original Reporter v1 export format"
```

---

### Task 3: SwiftData models and shared value types

**Files:**
- Create: `Sources/DispatchKit/Models/Values.swift`
- Create: `Sources/DispatchKit/Models/Question.swift`
- Create: `Sources/DispatchKit/Models/Report.swift`
- Create: `Sources/DispatchKit/Models/Response.swift`
- Create: `Sources/DispatchKit/Models/Vocabulary.swift`
- Create: `Sources/DispatchKit/Models/DispatchStore.swift`
- Test: `Tests/DispatchKitTests/ModelTests.swift`

**Interfaces:**
- Consumes: `QuestionType` from Task 2.
- Produces: `Question`, `Report`, `Response`, `TokenEntity`, `PersonEntity` @Model classes; value structs `AudioSample`, `LocationSnapshot`, `Placemark`, `WeatherObservation`, `PhotoRecord`, `HealthReading`, `FocusState`, `TokenValue`, `LocationAnswer`; enums `ReportKind`, `ReportTrigger`; `DispatchStore.inMemoryContainer() throws -> ModelContainer`. Every later task persists through these.

- [ ] **Step 1: Write the failing model round-trip test**

`Tests/DispatchKitTests/ModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func insertsAndFetchesModels() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let question = Question()
    question.uniqueIdentifier = "q-yesno"
    question.prompt = "Are you working?"
    question.type = .yesNo
    question.reportKinds = [.regular, .wake]
    context.insert(question)

    let report = Report()
    report.uniqueIdentifier = "snap-1"
    report.date = Date(timeIntervalSince1970: 1_455_235_734)
    report.timeZoneIdentifier = "GMT-0400"
    report.kind = .regular
    report.trigger = .manual
    report.audio = AudioSample(avg: -43.57, peak: -34.0)
    report.health = [HealthReading(type: "steps", value: 481, unit: "count")]
    report.focus = FocusState(label: "Work", isFocused: true)
    context.insert(report)

    let response = Response()
    response.uniqueIdentifier = "r-1b"
    response.questionPrompt = "Are you working?"
    response.answeredOptions = ["Yes"]
    response.report = report
    context.insert(response)
    try context.save()

    let reports = try context.fetch(FetchDescriptor<Report>())
    #expect(reports.count == 1)
    let fetched = try #require(reports.first)
    #expect(fetched.audio?.avg == -43.57)
    #expect(fetched.health.first?.value == 481)
    #expect(fetched.focus?.label == "Work")
    #expect(fetched.responses.count == 1)
    #expect(fetched.responses.first?.answeredOptions == ["Yes"])

    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.first?.type == .yesNo)
    #expect(questions.first?.reportKinds == [.regular, .wake])
}

@Test func cascadeDeletesResponses() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    let response = Response()
    response.report = report
    context.insert(report)
    context.insert(response)
    try context.save()

    context.delete(report)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Response>()).isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelTests`
Expected: FAIL — `cannot find 'DispatchStore' in scope`

- [ ] **Step 3: Implement value types**

`Sources/DispatchKit/Models/Values.swift`:

```swift
import Foundation

public enum ReportKind: String, Codable, Sendable, CaseIterable {
    case regular, wake, sleep
}

public enum ReportTrigger: String, Codable, Sendable, CaseIterable {
    case manual, notification, visitArrival, visitDeparture
    case wake, workoutEnd, widget, control, intent
}

/// Raw values match the original Reporter export (gist.github.com/dbreunig/9315705).
public enum ConnectionType: Int, Codable, Sendable {
    case cellular = 0
    case wifi = 1
    case none = 2
}

public struct AudioSample: Codable, Hashable, Sendable {
    public var avg: Double
    public var peak: Double
    public init(avg: Double, peak: Double) { self.avg = avg; self.peak = peak }
}

public struct Placemark: Codable, Hashable, Sendable {
    public var name: String?
    public var thoroughfare: String?
    public var subThoroughfare: String?
    public var locality: String?
    public var subLocality: String?
    public var administrativeArea: String?
    public var subAdministrativeArea: String?
    public var postalCode: String?
    public var country: String?
    public init() {}
}

public struct LocationSnapshot: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    public var speed: Double?
    public var course: Double?
    public var timestamp: Date?
    public var placemark: Placemark?
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WeatherObservation: Codable, Hashable, Sendable {
    public var tempF: Double?
    public var tempC: Double?
    public var condition: String?
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
    public init() {}
}

public struct PhotoRecord: Codable, Hashable, Sendable {
    public var uniqueIdentifier: String
    public var assetUrl: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var dateTime: Date?
    public var latitude: Double?
    public var longitude: Double?
    public init(uniqueIdentifier: String) { self.uniqueIdentifier = uniqueIdentifier }
}

/// One captured health metric. `type` is an open string (e.g. "steps",
/// "flightsClimbed", "heartRateAvg") so new HealthKit types need no migration.
public struct HealthReading: Codable, Hashable, Sendable {
    public var type: String
    public var value: Double
    public var unit: String
    public var startDate: Date?
    public var endDate: Date?
    public init(type: String, value: Double, unit: String, startDate: Date? = nil, endDate: Date? = nil) {
        self.type = type
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct FocusState: Codable, Hashable, Sendable {
    public var label: String?
    public var isFocused: Bool
    public init(label: String? = nil, isFocused: Bool) {
        self.label = label
        self.isFocused = isFocused
    }
}

public struct TokenValue: Codable, Hashable, Sendable {
    public var uniqueIdentifier: String
    public var text: String
    public init(uniqueIdentifier: String = UUID().uuidString, text: String) {
        self.uniqueIdentifier = uniqueIdentifier
        self.text = text
    }
}

public struct LocationAnswer: Codable, Hashable, Sendable {
    public var text: String?
    public var foursquareVenueId: String?
    public var location: LocationSnapshot?
    public init() {}
}
```

- [ ] **Step 4: Implement the @Model classes and store**

`Sources/DispatchKit/Models/Question.swift`:

```swift
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
```

`Sources/DispatchKit/Models/Report.swift`:

```swift
import Foundation
import SwiftData

@Model
public final class Report {
    public var uniqueIdentifier: String = UUID().uuidString
    public var date: Date = Date.distantPast
    public var timeZoneIdentifier: String = "GMT"
    public var kindRaw: String = ReportKind.regular.rawValue
    public var triggerRaw: String = ReportTrigger.manual.rawValue
    /// Original v1 `reportImpetus`, preserved verbatim on import.
    public var legacyImpetus: Int?
    public var isBackdated: Bool = false
    public var isDraft: Bool = false
    public var wasInBackground: Bool = false
    public var battery: Double?
    public var altitudeMeters: Double?
    public var connection: Int?
    public var audio: AudioSample?
    public var location: LocationSnapshot?
    public var weather: WeatherObservation?
    public var photos: [PhotoRecord] = []
    public var health: [HealthReading] = []
    public var focus: FocusState?
    public var stateOfMindSampleIDs: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \Response.report)
    public var responses: [Response] = []

    public init() {}

    public var kind: ReportKind {
        get { ReportKind(rawValue: kindRaw) ?? .regular }
        set { kindRaw = newValue.rawValue }
    }

    public var trigger: ReportTrigger {
        get { ReportTrigger(rawValue: triggerRaw) ?? .manual }
        set { triggerRaw = newValue.rawValue }
    }

    public var connectionType: ConnectionType? {
        connection.flatMap(ConnectionType.init(rawValue:))
    }
}
```

`Sources/DispatchKit/Models/Response.swift`:

```swift
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
```

`Sources/DispatchKit/Models/Vocabulary.swift`:

```swift
import Foundation
import SwiftData

@Model
public final class TokenEntity {
    public var text: String = ""
    public var usageCount: Int = 0
    public var questionCount: Int = 0
    public init() {}
}

@Model
public final class PersonEntity {
    public var text: String = ""
    public var usageCount: Int = 0
    public var questionCount: Int = 0
    public init() {}
}
```

`Sources/DispatchKit/Models/DispatchStore.swift`:

```swift
import Foundation
import SwiftData

public enum DispatchStore {
    public static let allModels: [any PersistentModel.Type] = [
        Question.self, Report.self, Response.self, TokenEntity.self, PersonEntity.self,
    ]

    public static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(allModels)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/DispatchKit/Models Tests/DispatchKitTests/ModelTests.swift
git commit -m "feat: SwiftData models and shared value types"
```

---

### Task 4: v1 importer (idempotent upsert + timezone derivation)

**Files:**
- Create: `Sources/DispatchKit/Import/V1Importer.swift`
- Test: `Tests/DispatchKitTests/V1ImporterTests.swift`

**Interfaces:**
- Consumes: `V1Export`/`V1DateParser` (Task 2), models + `DispatchStore` (Task 3).
- Produces: `V1Importer.importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary` where `ImportSummary` has `questionsImported: Int`, `reportsImported: Int`, `responsesImported: Int`, `skipped: Int`. Tasks 6–8 reuse `ImportSummary`; the app's import UI calls this.

- [ ] **Step 1: Write the failing importer tests**

`Tests/DispatchKitTests/V1ImporterTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func importsFixture() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    #expect(summary.questionsImported == 7)
    #expect(summary.reportsImported == 3)
    #expect(summary.responsesImported == 8)
    #expect(summary.skipped == 0)

    let reports = try context.fetch(FetchDescriptor<Report>())
    let snap1 = try #require(reports.first { $0.uniqueIdentifier == "snap-1" })
    // v1 steps land in the health array.
    #expect(snap1.health.first { $0.type == "steps" }?.value == 481)
    #expect(snap1.legacyImpetus == 0)
    #expect(snap1.trigger == .manual)
    #expect(snap1.timeZoneIdentifier == TimeZone(secondsFromGMT: -4 * 3600)!.identifier)
    #expect(snap1.weather?.condition == "Mostly Cloudy")
    #expect(snap1.location?.placemark?.locality == "Oakland")

    let snap2 = try #require(reports.first { $0.uniqueIdentifier == "snap-2" })
    #expect(snap2.photos.count == 1)
    #expect(snap2.trigger == .notification) // impetus 2 = notification-initiated
    #expect(snap2.connectionType == .wifi)  // connection 1
    #expect(snap2.responses.count == 3)

    // impetus 4 = wake report: kind and trigger recovered from v1 data.
    let snap3 = try #require(reports.first { $0.uniqueIdentifier == "snap-3" })
    #expect(snap3.kind == .wake)
    #expect(snap3.trigger == .wake)

    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.count == 7)
    // Imported multi-choice questions have no options (v1 export lacks them).
    let multi = try #require(questions.first { $0.uniqueIdentifier == "q-multi" })
    #expect(multi.choices.isEmpty)
    // Sort order follows export order.
    #expect(questions.sorted { $0.sortOrder < $1.sortOrder }.first?.uniqueIdentifier == "q-tokens")
}

@Test func importIsIdempotent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let data = try fixtureData("v1-sample")
    _ = try V1Importer.importExport(data, into: context)
    _ = try V1Importer.importExport(data, into: context)

    #expect(try context.fetch(FetchDescriptor<Report>()).count == 3)
    #expect(try context.fetch(FetchDescriptor<Question>()).count == 7)
    #expect(try context.fetch(FetchDescriptor<Response>()).count == 8)
}

@Test func importsRealExportIfPresent() throws {
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(try Data(contentsOf: URL(fileURLWithPath: path)), into: context)
    #expect(summary.reportsImported == 94)
    #expect(summary.questionsImported == 38)
    #expect(summary.skipped == 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter V1ImporterTests`
Expected: FAIL — `cannot find 'V1Importer' in scope`

- [ ] **Step 3: Implement the importer**

`Sources/DispatchKit/Import/V1Importer.swift`:

```swift
import Foundation
import SwiftData

public struct ImportSummary: Sendable, Equatable {
    public var questionsImported = 0
    public var reportsImported = 0
    public var responsesImported = 0
    public var skipped = 0
    public init() {}
}

public enum V1Importer {
    /// Idempotent: records are upserted by uniqueIdentifier; re-importing
    /// the same file changes nothing. Malformed records are skipped and
    /// counted, never fatal.
    public static func importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        let export = try V1Export.decode(from: data)
        var summary = ImportSummary()

        for (index, v1q) in export.questions.enumerated() {
            let question = try fetchOrCreateQuestion(id: v1q.uniqueIdentifier, in: context)
            question.prompt = v1q.prompt
            question.typeRaw = v1q.questionType
            question.placeholderString = v1q.placeholderString
            question.sortOrder = index
            summary.questionsImported += 1
        }

        for snapshot in export.snapshots {
            guard let parsed = snapshot.date.resolved else {
                summary.skipped += 1
                continue
            }
            let report = try fetchOrCreateReport(id: snapshot.uniqueIdentifier, in: context)
            report.date = parsed.date
            report.timeZoneIdentifier = TimeZone(secondsFromGMT: parsed.utcOffsetSeconds)?.identifier ?? "GMT"
            report.legacyImpetus = snapshot.reportImpetus
            // v1 impetus (gist.github.com/dbreunig/9315705): 0=button,
            // 1=button while asleep, 2=notification, 3=sleep report, 4=wake report.
            switch snapshot.reportImpetus ?? 0 {
            case 2:
                report.kind = .regular
                report.trigger = .notification
            case 3:
                report.kind = .sleep
                report.trigger = .manual
            case 4:
                report.kind = .wake
                report.trigger = .wake
            default:
                report.kind = .regular
                report.trigger = .manual
            }
            report.isDraft = snapshot.draft == 1
            report.wasInBackground = snapshot.background == 1
            report.battery = snapshot.battery
            report.altitudeMeters = snapshot.altitude
            report.connection = snapshot.connection
            report.audio = snapshot.audio.map { AudioSample(avg: $0.avg, peak: $0.peak) }
            report.location = snapshot.location.map(mapLocation)
            report.weather = snapshot.weather.map(mapWeather)
            report.photos = snapshot.photoSet?.photos.map(mapPhoto) ?? []
            report.health = snapshot.steps.map {
                [HealthReading(type: "steps", value: Double($0), unit: "count")]
            } ?? []
            summary.reportsImported += 1

            for v1r in snapshot.responses ?? [] {
                let response = try fetchOrCreateResponse(id: v1r.uniqueIdentifier, in: context)
                response.questionPrompt = v1r.questionPrompt
                response.tokens = v1r.tokens?.map { TokenValue(uniqueIdentifier: $0.uniqueIdentifier, text: $0.text) }
                response.answeredOptions = v1r.answeredOptions
                response.numericResponse = v1r.numericResponse
                response.textResponses = v1r.textResponses?.map { TokenValue(uniqueIdentifier: $0.uniqueIdentifier, text: $0.text) }
                response.locationResponse = v1r.locationResponse.map { lr in
                    var answer = LocationAnswer()
                    answer.text = lr.text
                    answer.foursquareVenueId = lr.foursquareVenueId
                    answer.location = lr.location.map(mapLocation)
                    return answer
                }
                response.report = report
                summary.responsesImported += 1
            }
        }

        try context.save()
        return summary
    }

    private static func fetchOrCreateQuestion(id: String, in context: ModelContext) throws -> Question {
        var descriptor = FetchDescriptor<Question>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let question = Question()
        question.uniqueIdentifier = id
        context.insert(question)
        return question
    }

    private static func fetchOrCreateReport(id: String, in context: ModelContext) throws -> Report {
        var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let report = Report()
        report.uniqueIdentifier = id
        context.insert(report)
        return report
    }

    private static func fetchOrCreateResponse(id: String, in context: ModelContext) throws -> Response {
        var descriptor = FetchDescriptor<Response>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let response = Response()
        response.uniqueIdentifier = id
        context.insert(response)
        return response
    }

    private static func mapLocation(_ v1: V1Location) -> LocationSnapshot {
        var snapshot = LocationSnapshot(latitude: v1.latitude, longitude: v1.longitude)
        snapshot.altitude = v1.altitude
        snapshot.horizontalAccuracy = v1.horizontalAccuracy
        snapshot.verticalAccuracy = v1.verticalAccuracy
        snapshot.speed = v1.speed
        snapshot.course = v1.course
        snapshot.timestamp = v1.timestamp?.resolved?.date
        snapshot.placemark = v1.placemark.map { pm in
            var placemark = Placemark()
            placemark.name = pm.name
            placemark.thoroughfare = pm.thoroughfare
            placemark.subThoroughfare = pm.subThoroughfare
            placemark.locality = pm.locality
            placemark.subLocality = pm.subLocality
            placemark.administrativeArea = pm.administrativeArea
            placemark.subAdministrativeArea = pm.subAdministrativeArea
            placemark.postalCode = pm.postalCode
            placemark.country = pm.country
            return placemark
        }
        return snapshot
    }

    private static func mapWeather(_ v1: V1Weather) -> WeatherObservation {
        var weather = WeatherObservation()
        weather.tempF = v1.tempF
        weather.tempC = v1.tempC
        weather.condition = v1.weather
        weather.relativeHumidity = v1.relativeHumidity
        weather.windMPH = v1.windMPH
        weather.windKPH = v1.windKPH
        weather.windGustMPH = v1.windGustMPH
        weather.windGustKPH = v1.windGustKPH
        weather.windDirection = v1.windDirection
        weather.windDegrees = v1.windDegrees
        weather.pressureIn = v1.pressureIn
        weather.pressureMb = v1.pressureMb
        weather.visibilityMi = v1.visibilityMi
        weather.visibilityKM = v1.visibilityKM
        weather.feelslikeF = v1.feelslikeF
        weather.feelslikeC = v1.feelslikeC
        weather.dewpointC = v1.dewpointC
        weather.precipTodayIn = v1.precipTodayIn
        weather.precipTodayMetric = v1.precipTodayMetric
        weather.uv = v1.uv
        weather.stationID = v1.stationID
        return weather
    }

    private static func mapPhoto(_ v1: V1Photo) -> PhotoRecord {
        var photo = PhotoRecord(uniqueIdentifier: v1.uniqueIdentifier)
        photo.assetUrl = v1.assetUrl
        photo.pixelWidth = v1.pixelWidth
        photo.pixelHeight = v1.pixelHeight
        photo.dateTime = v1.dateTime?.resolved?.date
        photo.latitude = v1.latitude
        photo.longitude = v1.longitude
        return photo
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter V1ImporterTests`
Expected: PASS (2 tests; real-export test no-ops without env var)

- [ ] **Step 5: Verify the real export imports cleanly**

Run: `DISPATCH_V1_EXPORT=$PWD/reporter-export.json swift test --filter importsRealExportIfPresent`
Expected: PASS — 94 reports, 38 questions, 0 skipped

- [ ] **Step 6: Commit**

```bash
git add Sources/DispatchKit/Import Tests/DispatchKitTests/V1ImporterTests.swift
git commit -m "feat: idempotent v1 importer with timezone derivation"
```

---

### Task 5: Vocabulary derivation (tokens & people)

**Files:**
- Create: `Sources/DispatchKit/Import/VocabularyBuilder.swift`
- Test: `Tests/DispatchKitTests/VocabularyTests.swift`

**Interfaces:**
- Consumes: models (Task 3), `V1Importer` (Task 4) in tests.
- Produces: `VocabularyBuilder.rebuild(in context: ModelContext) throws` — repopulates `TokenEntity`/`PersonEntity` with usage counts from all responses. The importer flow and Custom Tokens screen call this.

- [ ] **Step 1: Write the failing test**

`Tests/DispatchKitTests/VocabularyTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func rebuildsVocabularyFromResponses() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    try VocabularyBuilder.rebuild(in: context)

    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    // Token-type responses in fixture: "Working", "Coding" (q-tokens).
    #expect(Set(tokens.map(\.text)) == ["Working", "Coding"])
    #expect(tokens.first { $0.text == "Working" }?.usageCount == 1)
    #expect(tokens.first { $0.text == "Working" }?.questionCount == 1)

    let people = try context.fetch(FetchDescriptor<PersonEntity>())
    // People-type responses: "Melissa" (q-people, snap-3).
    #expect(people.map(\.text) == ["Melissa"])

    // Rebuild is idempotent (no duplicate rows).
    try VocabularyBuilder.rebuild(in: context)
    #expect(try context.fetch(FetchDescriptor<TokenEntity>()).count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VocabularyTests`
Expected: FAIL — `cannot find 'VocabularyBuilder' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Import/VocabularyBuilder.swift`:

```swift
import Foundation
import SwiftData

public enum VocabularyBuilder {
    /// Rebuilds token/person vocabularies from all stored responses.
    /// People-type questions feed PersonEntity; token-type feed TokenEntity.
    public static func rebuild(in context: ModelContext) throws {
        let questions = try context.fetch(FetchDescriptor<Question>())
        let typeByPrompt = Dictionary(questions.map { ($0.prompt, $0.type) },
                                      uniquingKeysWith: { first, _ in first })
        let responses = try context.fetch(FetchDescriptor<Response>())

        struct Tally { var uses = 0; var prompts = Set<String>() }
        var tokenTally: [String: Tally] = [:]
        var personTally: [String: Tally] = [:]

        for response in responses {
            guard let values = response.tokens, !values.isEmpty else { continue }
            let isPeople = typeByPrompt[response.questionPrompt] == .people
            for value in values {
                var tally = (isPeople ? personTally : tokenTally)[value.text] ?? Tally()
                tally.uses += 1
                tally.prompts.insert(response.questionPrompt)
                if isPeople { personTally[value.text] = tally } else { tokenTally[value.text] = tally }
            }
        }

        try context.delete(model: TokenEntity.self)
        try context.delete(model: PersonEntity.self)
        for (text, tally) in tokenTally {
            let entity = TokenEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }
        for (text, tally) in personTally {
            let entity = PersonEntity()
            entity.text = text
            entity.usageCount = tally.uses
            entity.questionCount = tally.prompts.count
            context.insert(entity)
        }
        try context.save()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VocabularyTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/DispatchKit/Import/VocabularyBuilder.swift Tests/DispatchKitTests/VocabularyTests.swift
git commit -m "feat: derive token/person vocabularies from responses"
```

---

### Task 6: v2 DTOs and exporter

**Files:**
- Create: `Sources/DispatchKit/V2/V2Models.swift`
- Create: `Sources/DispatchKit/V2/V2Exporter.swift`
- Test: `Tests/DispatchKitTests/V2ExportTests.swift`

**Interfaces:**
- Consumes: models (Task 3), value structs (reused directly as v2 payloads).
- Produces: `V2Export` Codable (`schemaVersion: Int`, `questions: [V2Question]`, `reports: [V2Report]`); `V2Exporter.exportData(from context: ModelContext) throws -> Data`. Task 7's importer decodes exactly this; the app's share-sheet export and backups call `exportData`.

- [ ] **Step 1: Write the failing exporter tests**

`Tests/DispatchKitTests/V2ExportTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func exportsV2JSON() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let data = try V2Exporter.exportData(from: context)
    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: data)

    #expect(decoded.schemaVersion == 2)
    #expect(decoded.questions.count == 7)
    #expect(decoded.reports.count == 3)

    let snap1 = try #require(decoded.reports.first { $0.uniqueIdentifier == "snap-1" })
    #expect(snap1.kind == .regular)
    #expect(snap1.trigger == .manual)
    #expect(snap1.legacyImpetus == 0)
    #expect(snap1.timeZone == TimeZone(secondsFromGMT: -4 * 3600)!.identifier)
    #expect(snap1.health?.first { $0.type == "steps" }?.value == 481)
    #expect(snap1.responses?.count == 4)

    let multi = try #require(decoded.questions.first { $0.uniqueIdentifier == "q-multi" })
    #expect(multi.questionType == QuestionType.multipleChoice.rawValue)
    #expect(multi.reportKinds == [.regular])
}

@Test func exportIsDeterministic() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)
    let first = try V2Exporter.exportData(from: context)
    let second = try V2Exporter.exportData(from: context)
    #expect(first == second) // sorted keys + sorted records
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter V2ExportTests`
Expected: FAIL — `cannot find 'V2Exporter' in scope`

- [ ] **Step 3: Implement the v2 DTOs and exporter**

`Sources/DispatchKit/V2/V2Models.swift`:

```swift
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
```

`Sources/DispatchKit/V2/V2Exporter.swift`:

```swift
import Foundation
import SwiftData

public enum V2Exporter {
    public static func export(from context: ModelContext) throws -> V2Export {
        var export = V2Export()

        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)]))
        export.questions = questions.map { q in
            V2Question(uniqueIdentifier: q.uniqueIdentifier, prompt: q.prompt,
                       questionType: q.typeRaw, placeholderString: q.placeholderString,
                       choices: q.choices.isEmpty ? nil : q.choices,
                       sortOrder: q.sortOrder, isEnabled: q.isEnabled,
                       stateOfMindKind: q.stateOfMindKind, reportKinds: q.reportKinds)
        }

        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date)]))
        export.reports = reports.map { r in
            var dto = V2Report(uniqueIdentifier: r.uniqueIdentifier, date: r.date,
                               timeZone: r.timeZoneIdentifier, kind: r.kind, trigger: r.trigger)
            dto.legacyImpetus = r.legacyImpetus
            dto.isBackdated = r.isBackdated
            dto.isDraft = r.isDraft
            dto.wasInBackground = r.wasInBackground
            dto.battery = r.battery
            dto.altitudeMeters = r.altitudeMeters
            dto.connection = r.connection
            dto.audio = r.audio
            dto.location = r.location
            dto.weather = r.weather
            dto.photos = r.photos.isEmpty ? nil : r.photos
            dto.health = r.health.isEmpty ? nil : r.health
            dto.focus = r.focus
            dto.stateOfMindSampleIDs = r.stateOfMindSampleIDs.isEmpty ? nil : r.stateOfMindSampleIDs
            let responses = r.responses
                .sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
                .map { resp in
                    var rdto = V2Response(uniqueIdentifier: resp.uniqueIdentifier,
                                          questionPrompt: resp.questionPrompt)
                    rdto.tokens = resp.tokens
                    rdto.answeredOptions = resp.answeredOptions
                    rdto.locationResponse = resp.locationResponse
                    rdto.numericResponse = resp.numericResponse
                    rdto.textResponses = resp.textResponses
                    return rdto
                }
            dto.responses = responses.isEmpty ? nil : responses
            return dto
        }
        return export
    }

    public static func exportData(from context: ModelContext) throws -> Data {
        try JSONEncoder.v2.encode(try export(from: context))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter V2ExportTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/DispatchKit/V2 Tests/DispatchKitTests/V2ExportTests.swift
git commit -m "feat: v2 schema DTOs and deterministic exporter"
```

---

### Task 7: v2 importer and full round-trip test

**Files:**
- Create: `Sources/DispatchKit/Import/V2Importer.swift`
- Test: `Tests/DispatchKitTests/RoundTripTests.swift`

**Interfaces:**
- Consumes: `V2Export`/`JSONDecoder.v2` (Task 6), models (Task 3), `ImportSummary` (Task 4).
- Produces: `V2Importer.importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary`. The app's import UI dispatches on `schemaVersion` between `V1Importer` and `V2Importer`; backups restore through this.

- [ ] **Step 1: Write the failing round-trip tests**

`Tests/DispatchKitTests/RoundTripTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

/// v1 fixture → models → v2 JSON → fresh models → v2 JSON must be byte-identical.
@Test func v1ToV2RoundTripIsLossless() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: contextA)
    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    let summary = try V2Importer.importExport(exportA, into: contextB)
    #expect(summary.questionsImported == 7)
    #expect(summary.reportsImported == 3)
    #expect(summary.responsesImported == 8)

    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}

@Test func v2ImportIsIdempotent() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: contextA)
    let data = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(data, into: contextB)
    _ = try V2Importer.importExport(data, into: contextB)
    #expect(try contextB.fetch(FetchDescriptor<Report>()).count == 3)
    #expect(try contextB.fetch(FetchDescriptor<Response>()).count == 8)
}

@Test func v2ImportRejectsWrongSchemaVersion() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let bad = Data(#"{"schemaVersion": 3, "questions": [], "reports": []}"#.utf8)
    #expect(throws: V2Importer.ImportError.unsupportedSchemaVersion(3)) {
        try V2Importer.importExport(bad, into: context)
    }
}

@Test func realExportRoundTripsIfPresent() throws {
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try Data(contentsOf: URL(fileURLWithPath: path)), into: contextA)
    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RoundTripTests`
Expected: FAIL — `cannot find 'V2Importer' in scope`

- [ ] **Step 3: Implement the v2 importer**

`Sources/DispatchKit/Import/V2Importer.swift`:

```swift
import Foundation
import SwiftData

public enum V2Importer {
    public enum ImportError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    public static func importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        let export = try JSONDecoder.v2.decode(V2Export.self, from: data)
        guard export.schemaVersion == DispatchKitInfo.schemaVersion else {
            throw ImportError.unsupportedSchemaVersion(export.schemaVersion)
        }
        var summary = ImportSummary()

        for dto in export.questions {
            let id = dto.uniqueIdentifier
            var descriptor = FetchDescriptor<Question>(predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let question = try context.fetch(descriptor).first ?? {
                let q = Question()
                q.uniqueIdentifier = id
                context.insert(q)
                return q
            }()
            question.prompt = dto.prompt
            question.typeRaw = dto.questionType
            question.placeholderString = dto.placeholderString
            question.choices = dto.choices ?? []
            question.sortOrder = dto.sortOrder
            question.isEnabled = dto.isEnabled
            question.stateOfMindKind = dto.stateOfMindKind
            question.reportKinds = dto.reportKinds
            summary.questionsImported += 1
        }

        for dto in export.reports {
            let id = dto.uniqueIdentifier
            var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let report = try context.fetch(descriptor).first ?? {
                let r = Report()
                r.uniqueIdentifier = id
                context.insert(r)
                return r
            }()
            report.date = dto.date
            report.timeZoneIdentifier = dto.timeZone
            report.kind = dto.kind
            report.trigger = dto.trigger
            report.legacyImpetus = dto.legacyImpetus
            report.isBackdated = dto.isBackdated
            report.isDraft = dto.isDraft
            report.wasInBackground = dto.wasInBackground
            report.battery = dto.battery
            report.altitudeMeters = dto.altitudeMeters
            report.connection = dto.connection
            report.audio = dto.audio
            report.location = dto.location
            report.weather = dto.weather
            report.photos = dto.photos ?? []
            report.health = dto.health ?? []
            report.focus = dto.focus
            report.stateOfMindSampleIDs = dto.stateOfMindSampleIDs ?? []
            summary.reportsImported += 1

            for rdto in dto.responses ?? [] {
                let rid = rdto.uniqueIdentifier
                var rdescriptor = FetchDescriptor<Response>(predicate: #Predicate { $0.uniqueIdentifier == rid })
                rdescriptor.fetchLimit = 1
                let response = try context.fetch(rdescriptor).first ?? {
                    let resp = Response()
                    resp.uniqueIdentifier = rid
                    context.insert(resp)
                    return resp
                }()
                response.questionPrompt = rdto.questionPrompt
                response.tokens = rdto.tokens
                response.answeredOptions = rdto.answeredOptions
                response.locationResponse = rdto.locationResponse
                response.numericResponse = rdto.numericResponse
                response.textResponses = rdto.textResponses
                response.report = report
                summary.responsesImported += 1
            }
        }

        try context.save()
        return summary
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RoundTripTests`
Expected: PASS (3 tests; real-export test no-ops without env var)

- [ ] **Step 5: Verify the real export round-trips**

Run: `DISPATCH_V1_EXPORT=$PWD/reporter-export.json swift test --filter realExportRoundTripsIfPresent`
Expected: PASS — all 94 real snapshots survive v1→v2→v2 byte-identically

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, no regressions

- [ ] **Step 7: Commit**

```bash
git add Sources/DispatchKit/Import/V2Importer.swift Tests/DispatchKitTests/RoundTripTests.swift
git commit -m "feat: v2 importer with lossless round-trip guarantee"
```

---

### Task 8: CSV exporter

**Files:**
- Create: `Sources/DispatchKit/Export/CSVExporter.swift`
- Test: `Tests/DispatchKitTests/CSVExportTests.swift`

**Interfaces:**
- Consumes: models (Task 3).
- Produces: `CSVExporter.exportCSV(from context: ModelContext) throws -> String` — header + one row per report, question columns ordered by `sortOrder`. The app's share-sheet export calls this.

- [ ] **Step 1: Write the failing tests**

`Tests/DispatchKitTests/CSVExportTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func exportsCSVWithQuestionColumns() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let csv = try CSVExporter.exportCSV(from: context)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // Header: fixed sensor columns then question prompts in sortOrder.
    let header = lines[0]
    #expect(header.hasPrefix("date,timeZone,kind,trigger,latitude,longitude,place,weather,tempF,altitudeMeters,audioAvg,audioPeak,battery,steps,photoCount"))
    #expect(header.contains("What are you doing?"))
    #expect(header.contains("Who are you with?"))

    // 3 reports → 4 lines (header + 3), oldest first.
    #expect(lines.count == 4)
    let snap1Row = try #require(lines.first { $0.contains("2016-02-11") })
    #expect(snap1Row.contains("Working|Coding")) // tokens joined with |
    #expect(snap1Row.contains(",Yes,"))          // answeredOptions joined
    #expect(snap1Row.contains(",481,"))          // steps from health array

    // snap-2 files at 20:10 -0400 == 00:10Z the NEXT day; CSV dates are UTC ISO8601.
    let snap2Row = try #require(lines.first { $0.contains("2015-10-22") })
    #expect(snap2Row.contains("The Grand"))      // locationResponse text
}

@Test func escapesCSVFields() {
    #expect(CSVExporter.escape(#"say "hi", ok"#) == #""say ""hi"", ok""#)
    #expect(CSVExporter.escape("plain") == "plain")
    #expect(CSVExporter.escape("line\nbreak") == "\"line\nbreak\"")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CSVExportTests`
Expected: FAIL — `cannot find 'CSVExporter' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Export/CSVExporter.swift`:

```swift
import Foundation
import SwiftData

public enum CSVExporter {
    static let sensorColumns = [
        "date", "timeZone", "kind", "trigger", "latitude", "longitude", "place",
        "weather", "tempF", "altitudeMeters", "audioAvg", "audioPeak",
        "battery", "steps", "photoCount",
    ]

    public static func exportCSV(from context: ModelContext) throws -> String {
        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)]))
        let prompts = questions.map(\.prompt)
        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date)]))

        var rows = [(sensorColumns + prompts).map(escape).joined(separator: ",")]

        let dateFormatter = ISO8601DateFormatter()
        for report in reports {
            let byPrompt = Dictionary(report.responses.map { ($0.questionPrompt, $0) },
                                      uniquingKeysWith: { first, _ in first })
            var fields: [String] = [
                dateFormatter.string(from: report.date),
                report.timeZoneIdentifier,
                report.kind.rawValue,
                report.trigger.rawValue,
                report.location.map { String($0.latitude) } ?? "",
                report.location.map { String($0.longitude) } ?? "",
                report.location?.placemark?.locality ?? "",
                report.weather?.condition ?? "",
                report.weather?.tempF.map { String($0) } ?? "",
                report.altitudeMeters.map { String($0) } ?? "",
                report.audio.map { String($0.avg) } ?? "",
                report.audio.map { String($0.peak) } ?? "",
                report.battery.map { String($0) } ?? "",
                report.health.first { $0.type == "steps" }.map { String(Int($0.value)) } ?? "",
                String(report.photos.count),
            ]
            for prompt in prompts {
                fields.append(flatten(byPrompt[prompt]))
            }
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func flatten(_ response: Response?) -> String {
        guard let response else { return "" }
        if let tokens = response.tokens { return tokens.map(\.text).joined(separator: "|") }
        if let options = response.answeredOptions { return options.joined(separator: "|") }
        if let location = response.locationResponse { return location.text ?? "" }
        if let numeric = response.numericResponse { return numeric }
        if let texts = response.textResponses { return texts.map(\.text).joined(separator: "|") }
        return ""
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CSVExportTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/DispatchKit/Export Tests/DispatchKitTests/CSVExportTests.swift
git commit -m "feat: CSV export with per-question columns"
```

---

### Task 9: App shell (XcodeGen) + CI

**Files:**
- Create: `project.yml`
- Create: `App/Sources/DispatchApp.swift`
- Create: `App/Sources/ContentView.swift`
- Create: `App/Resources/Info.plist` (generated properties via project.yml — file only if xcodegen requires; see step 2)
- Create: `.github/workflows/ci.yml`
- Modify: `.gitignore` (ignore generated `*.xcodeproj`)

**Interfaces:**
- Consumes: `DispatchKit` library, `DispatchStore.allModels`.
- Produces: a buildable `Dispatch.xcodeproj` (generated, not committed) with app module `DispatchApp`, product name `Dispatch`; CI running `swift test`. Later plans add targets (widgets, Focus filter extension) to `project.yml`.

- [ ] **Step 1: Install XcodeGen**

Run: `brew install xcodegen`
Expected: `xcodegen` on PATH (`xcodegen --version` prints a version)

- [ ] **Step 2: Write the project definition**

`project.yml`:

```yaml
name: Dispatch
options:
  bundleIdPrefix: com.robbiet480
  deploymentTarget:
    iOS: "26.0"
packages:
  DispatchKit:
    path: .
targets:
  DispatchApp:
    type: application
    platform: iOS
    sources: [App/Sources]
    dependencies:
      - package: DispatchKit
    settings:
      base:
        PRODUCT_NAME: Dispatch
        PRODUCT_BUNDLE_IDENTIFIER: com.robbiet480.dispatch
        PRODUCT_MODULE_NAME: DispatchApp
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: 0.1.0
        SWIFT_VERSION: 6.0
```

- [ ] **Step 3: Write the app entry point**

`App/Sources/DispatchApp.swift`:

```swift
import DispatchKit
import SwiftData
import SwiftUI

@main
struct DispatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(try! ModelContainer(for: Schema(DispatchStore.allModels)))
    }
}
```

`App/Sources/ContentView.swift`:

```swift
import DispatchKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Query private var reports: [Report]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 64))
            Text("Dispatch")
                .font(.title)
            Text("\(reports.count) reports")
                .font(.subheadline)
        }
    }
}
```

- [ ] **Step 4: Generate and build**

```bash
echo "Dispatch.xcodeproj/" >> .gitignore
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build | tail -5
```

Expected: `BUILD SUCCEEDED` (adjust simulator name to one from `xcrun simctl list devices available` if iPhone 17 is absent)

- [ ] **Step 5: Add CI**

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.0.app || sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Run DispatchKit tests
        run: swift test
```

- [ ] **Step 6: Run the full suite one last time**

Run: `swift test`
Expected: PASS — all tests green

- [ ] **Step 7: Commit**

```bash
git add project.yml App .github .gitignore
git commit -m "feat: Dispatch app shell (XcodeGen) and CI"
```

---

## Plan sequence (later plans, written after this one executes)

1. **This plan** — foundation: models, codecs, import/export. ✅ testable via `swift test`
2. Plan 2 — report flow UI + sensor capture pipeline (mocked sensors first, then CoreLocation/WeatherKit/HealthKit/audio/photos/Focus capture)
3. Plan 3 — home, reports list/detail, question settings, custom tokens, themes, onboarding
4. Plan 4 — prompting engine (timed distributions, interactive notifications + snooze, visit/Focus/wake/workout triggers, App Intents)
5. Plan 5 — visualizations + State of Mind write-through
6. Plan 6 — widgets + Control Center + weekly digest (Foundation Models)
7. Plan 7 — search + Spotlight, app lock, backfill
8. Plan 8 — iCloud sync config, auto-backup, export UI, privacy manifest, accessibility pass, README, release
9. Plan 9 — tester experience: onboarding permission cascade, human-readable workout names, async import with progress, sensor failure hints
