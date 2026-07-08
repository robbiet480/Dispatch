# Dispatch Plan 2: Report Flow + Sensor Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working report flow on device/simulator: tap REPORT → sensor-capture checklist ("GETTING WEATHER…") → paged questions (all 7 types) → saved Report with responses, health readings, and vocabulary updates — with every system sensor behind a protocol so the flow is fully testable with mocks.

**Architecture:** DispatchKit gains the platform-neutral capture core (SensorProvider protocol, CaptureCoordinator with per-sensor timeouts and an AsyncStream of progress events, SensorSettings, ReportBuilder, SurveyViewModel) — all `swift test`-covered. The app target gains thin concrete providers (CoreLocation, WeatherKit, HealthKit, AVAudioRecorder, PhotoKit, UIDevice, NWPathMonitor, INFocusStatusCenter) and the SwiftUI survey flow. An XCUITest drives the whole flow with mock providers injected via launch argument.

**Tech Stack:** Swift 6.3, Swift Testing, SwiftData, SwiftUI @Observable, CoreLocation, WeatherKit, HealthKit, AVFAudio, PhotoKit, Network, Intents (Focus status), XcodeGen, XCUITest.

**Spec:** `docs/superpowers/specs/2026-07-07-reporter-clone-design.md` (§3 report flow, §4 context capture, §10 testing)

## Global Constraints

- Minimum deployment: iOS 26 (app), macOS 26 (DispatchKit tests). Modules: library `DispatchKit`, app `DispatchApp` (product name `Dispatch`) — never a module named `Dispatch`.
- Every sensor is an independent async task with a per-sensor timeout (default 10 s); failure/timeout/disabled degrades to a visible outcome, NEVER blocks or fails the report.
- Audio display formula: display dB = (raw dBFS + 65) × 2; label scale (display value): < 30 "EXTREMELY QUIET", 30–<50 "QUIET", 50–<70 "MODERATE", 70–<90 "LOUD", ≥ 90 "EXTREMELY LOUD".
- Questions shown in a survey: `isEnabled == true`, `reportKinds` contains the report's kind, ordered by `sortOrder` then `uniqueIdentifier`.
- All new @Model properties (none planned) would need defaults/optionals; dedupe stays by `uniqueIdentifier` in code.
- Vocabulary is rebuilt (`VocabularyBuilder.rebuild`) after every report save so token/people autocomplete stays fresh.
- All DispatchKit tests use Swift Testing via `swift test`; never commit `/IMG_*.PNG` or `/reporter-export.json`.
- Commit after every green test cycle; push to `origin main` after every commit.
- State of Mind write-through, Focus *labels* (Focus Filter extension), and the notification engine are LATER plans (4–5). Plan 2 captures only the Focus boolean (INFocusStatusCenter).
- HealthKit medications: implement ONLY if the installed SDK exposes a public dose-event API (check for `HKMedicationDoseEvent`/medication types in the iOS 26 SDK). If absent, omit the medications reading entirely and state so in the task report — do not stub or fake it.

---

### Task 1: Test hygiene — fictional fixture, fallback tests, CSV escape coverage, CI app build

**Files:**
- Modify: `Tests/DispatchKitTests/Fixtures/v1-sample.json`
- Modify: `Tests/DispatchKitTests/V1ImporterTests.swift`
- Modify: `Tests/DispatchKitTests/CSVExportTests.swift`
- Modify: `Tests/DispatchKitTests/VocabularyTests.swift`
- Create: `Tests/DispatchKitTests/RawValueFallbackTests.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: existing fixture and tests.
- Produces: a fixture free of personal data; tests for enum raw-value fallbacks; end-to-end CSV escaping proof; CI that also builds the app target.

- [ ] **Step 1: Fictionalize the fixture (exact replacements, fixture + tests together)**

Apply these exact string replacements in `v1-sample.json` AND in every test assertion that references them (`V1ImporterTests.swift`, `CSVExportTests.swift`, `VocabularyTests.swift`):

| Old | New |
|---|---|
| `Oakland` | `Riverton` |
| `Valdez St` | `Main St` |
| `2201–2295 Valdez St` | `100–120 Main St` |
| `The Grand` | `The Plaza` |
| `Melissa` | `Alex` |
| `KCAOAKLA38` | `KTEST1` |
| `Alameda` | `Summit` |
| `Waverly` | `Old Town` |

Do not change dates, offsets, coordinates-adjacent assertions, or counts — only these strings. Change `"latitude": 37.8116, "longitude": -122.2642` style coordinates to `"latitude": 40.0001, "longitude": -75.0001` (all coordinate pairs in the fixture; no test asserts coordinate values — verify with grep before assuming).

- [ ] **Step 2: Add an end-to-end CSV escape row and raw-value fallback tests**

Append to the fixture's snap-1 `responses` array (inside the JSON):

```json
{"questionPrompt": "What did you learn today?", "uniqueIdentifier": "r-1e",
 "textResponses": [{"uniqueIdentifier": "tr-2", "text": "Commas, and \"quotes\" happen"}]}
```

In `CSVExportTests.swift`, update `exportsCSVWithQuestionColumns`: response count expectations change from 8 to 9 anywhere asserted (`V1ImporterTests.importsFixture` asserts `responsesImported == 8` → 9; `importIsIdempotent` asserts Response count 8 → 9; `RoundTripTests` asserts `responsesImported == 7`? — grep for `== 8` in tests and update each hit that counts responses). Add to the CSV test:

```swift
let snap1Row2 = try #require(lines.first { $0.contains("2016-02-11") })
#expect(snap1Row2.contains(#""Commas, and ""quotes"" happen""#))
```

Create `Tests/DispatchKitTests/RawValueFallbackTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

@Test func unknownRawValuesFallBackToDefaults() {
    let report = Report()
    report.kindRaw = "definitely-not-a-kind"
    report.triggerRaw = "definitely-not-a-trigger"
    report.connection = 99
    #expect(report.kind == .regular)
    #expect(report.trigger == .manual)
    #expect(report.connectionType == nil)

    let question = Question()
    question.typeRaw = 99
    question.reportKindsRaw = ["nope", "wake"]
    #expect(question.type == .tokens)
    #expect(question.reportKinds == [.wake])
}
```

- [ ] **Step 3: Run tests to verify updated expectations**

Run: `swift test`
Expected: PASS (all tests, incl. new file). If any fixture-string assertion was missed, the failure names it — fix and re-run.

- [ ] **Step 4: Add the app build job to CI**

In `.github/workflows/ci.yml`, add a second job after `test`:

```yaml
  build-app:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.0.app || sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        run: xcodegen generate
      - name: Build app
        run: |
          DEST_ID=$(xcrun simctl list devices available --json | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(dev['udid'] for devs in d.values() for dev in devs if 'iPhone' in dev['name']))")
          xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination "id=$DEST_ID" build
```

- [ ] **Step 5: Verify the local equivalent builds**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -2`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit and push**

```bash
git add -A && git commit -m "test: fictional fixture data, raw-value fallback + CSV escape coverage, CI app build" && git push origin main
```

---

### Task 2: SensorSettings (toggles + units)

**Files:**
- Create: `Sources/DispatchKit/Capture/SensorSettings.swift`
- Test: `Tests/DispatchKitTests/SensorSettingsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SensorKind` enum; `SensorSettings` class: `init(defaults: UserDefaults)`, `isEnabled(_ kind: SensorKind) -> Bool` (default true), `setEnabled(_ kind: SensorKind, _ value: Bool)`, `var temperatureUnit: TemperatureUnit` (`.fahrenheit` default), `var lengthUnit: LengthUnit` (`.feet` default). CaptureCoordinator (Task 3) and the app's sensor-settings screen (Plan 3) consume this.

- [ ] **Step 1: Write the failing tests**

`Tests/DispatchKitTests/SensorSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

private func freshDefaults() -> UserDefaults {
    let name = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func sensorsDefaultToEnabled() {
    let settings = SensorSettings(defaults: freshDefaults())
    for kind in SensorKind.allCases {
        #expect(settings.isEnabled(kind))
    }
}

@Test func togglePersistsPerKind() {
    let defaults = freshDefaults()
    let settings = SensorSettings(defaults: defaults)
    settings.setEnabled(.weather, false)
    #expect(!settings.isEnabled(.weather))
    #expect(settings.isEnabled(.location))
    let reloaded = SensorSettings(defaults: defaults)
    #expect(!reloaded.isEnabled(.weather))
}

@Test func unitsDefaultToImperial() {
    let settings = SensorSettings(defaults: freshDefaults())
    #expect(settings.temperatureUnit == .fahrenheit)
    #expect(settings.lengthUnit == .feet)
    settings.temperatureUnit = .celsius
    settings.lengthUnit = .meters
    #expect(settings.temperatureUnit == .celsius)
    #expect(settings.lengthUnit == .meters)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SensorSettingsTests`
Expected: FAIL — `cannot find 'SensorSettings' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Capture/SensorSettings.swift`:

```swift
import Foundation

/// Every capturable context source, each independently toggleable.
public enum SensorKind: String, Codable, CaseIterable, Sendable {
    case location, weather, altitude, photos, audio, battery, connection, focus
    case healthSteps, healthFlights, healthHeart, healthHRV, healthRestingHeart
    case healthSleep, healthWorkouts, healthCaffeine, healthMedications
}

public enum TemperatureUnit: String, Codable, Sendable { case fahrenheit, celsius }
public enum LengthUnit: String, Codable, Sendable { case feet, meters }

/// UserDefaults-backed sensor toggles and display units. All sensors
/// default to enabled; units default to imperial (matches the original app).
public final class SensorSettings: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ kind: SensorKind) -> String { "sensor.enabled.\(kind.rawValue)" }

    public func isEnabled(_ kind: SensorKind) -> Bool {
        defaults.object(forKey: key(kind)) as? Bool ?? true
    }

    public func setEnabled(_ kind: SensorKind, _ value: Bool) {
        defaults.set(value, forKey: key(kind))
    }

    public var temperatureUnit: TemperatureUnit {
        get { defaults.string(forKey: "units.temperature").flatMap(TemperatureUnit.init(rawValue:)) ?? .fahrenheit }
        set { defaults.set(newValue.rawValue, forKey: "units.temperature") }
    }

    public var lengthUnit: LengthUnit {
        get { defaults.string(forKey: "units.length").flatMap(LengthUnit.init(rawValue:)) ?? .feet }
        set { defaults.set(newValue.rawValue, forKey: "units.length") }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SensorSettingsTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit and push**

```bash
git add Sources/DispatchKit/Capture Tests/DispatchKitTests/SensorSettingsTests.swift
git commit -m "feat: sensor toggles and unit settings" && git push origin main
```

---

### Task 3: Capture core — providers, coordinator, audio scale

**Files:**
- Create: `Sources/DispatchKit/Capture/SensorProvider.swift`
- Create: `Sources/DispatchKit/Capture/CaptureCoordinator.swift`
- Create: `Sources/DispatchKit/Capture/AudioLevel.swift`
- Test: `Tests/DispatchKitTests/CaptureCoordinatorTests.swift`
- Test: `Tests/DispatchKitTests/AudioLevelTests.swift`

**Interfaces:**
- Consumes: `SensorKind`/`SensorSettings` (Task 2); value structs from Models/Values.swift.
- Produces:
  - `SensorPayload` enum: `.location(LocationSnapshot)`, `.weather(WeatherObservation)`, `.altitude(Double)`, `.photos(count: Int, records: [PhotoRecord])`, `.audio(AudioSample)`, `.battery(Double)`, `.connection(Int)`, `.focus(FocusState)`, `.health([HealthReading])`
  - `SensorOutcome` enum: `.captured(SensorPayload)`, `.unavailable(reason: String)`, `.disabled`
  - `protocol SensorProvider: Sendable { var kind: SensorKind { get }; func capture() async throws -> SensorPayload }`
  - `struct CaptureEvent: Sendable { let kind: SensorKind; let outcome: SensorOutcome }`
  - `CaptureCoordinator.capture(providers: [any SensorProvider], settings: SensorSettings, timeout: Duration) -> AsyncStream<CaptureEvent>` — one event per provider, all concurrent, per-provider timeout; stream finishes when all providers resolve.
  - `AudioLevel.displayValue(fromRaw: Double) -> Double` and `AudioLevel.label(forDisplay: Double) -> String`.
  - App UI (Task 9) and ReportBuilder (Task 4) consume outcomes.

- [ ] **Step 1: Write the failing tests**

`Tests/DispatchKitTests/AudioLevelTests.swift`:

```swift
import Testing
@testable import DispatchKit

@Test func displayFormulaMatchesOriginal() {
    // Screenshot ground truth: raw −52.8 dBFS displays as 24.40 DB.
    #expect(abs(AudioLevel.displayValue(fromRaw: -52.8) - 24.4) < 0.001)
    #expect(AudioLevel.displayValue(fromRaw: -65) == 0)
}

@Test func labelScale() {
    #expect(AudioLevel.label(forDisplay: 24.4) == "EXTREMELY QUIET")
    #expect(AudioLevel.label(forDisplay: 30) == "QUIET")
    #expect(AudioLevel.label(forDisplay: 55) == "MODERATE")
    #expect(AudioLevel.label(forDisplay: 71) == "LOUD")
    #expect(AudioLevel.label(forDisplay: 95) == "EXTREMELY LOUD")
}
```

`Tests/DispatchKitTests/CaptureCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

struct StubProvider: SensorProvider {
    let kind: SensorKind
    let delay: Duration
    let result: Result<SensorPayload, Error>

    func capture() async throws -> SensorPayload {
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

struct StubError: Error {}

private func collect(_ stream: AsyncStream<CaptureEvent>) async -> [SensorKind: SensorOutcome] {
    var outcomes: [SensorKind: SensorOutcome] = [:]
    for await event in stream { outcomes[event.kind] = event.outcome }
    return outcomes
}

private func testSettings() -> SensorSettings {
    let name = "capture-test-\(UUID().uuidString)"
    return SensorSettings(defaults: UserDefaults(suiteName: name)!)
}

@Test func capturesAllProvidersConcurrently() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .battery, delay: .milliseconds(10), result: .success(.battery(0.5))),
        StubProvider(kind: .audio, delay: .milliseconds(10), result: .success(.audio(AudioSample(avg: -40, peak: -20)))),
    ]
    let start = ContinuousClock.now
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .seconds(1)))
    #expect(outcomes.count == 2)
    guard case .captured(.battery(let level)) = outcomes[.battery] else { Issue.record("battery missing"); return }
    #expect(level == 0.5)
    // Concurrent, not serial: two 10ms providers well under 500ms total.
    #expect(ContinuousClock.now - start < .milliseconds(500))
}

@Test func timeoutYieldsUnavailable() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .weather, delay: .seconds(5), result: .success(.altitude(1))),
        StubProvider(kind: .battery, delay: .milliseconds(1), result: .success(.battery(1.0))),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .milliseconds(50)))
    guard case .unavailable = outcomes[.weather] else { Issue.record("expected timeout unavailable"); return }
    guard case .captured = outcomes[.battery] else { Issue.record("fast provider should capture"); return }
}

@Test func errorsYieldUnavailable() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .location, delay: .milliseconds(1), result: .failure(StubError())),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .seconds(1)))
    guard case .unavailable = outcomes[.location] else { Issue.record("expected unavailable"); return }
}

@Test func disabledSensorsSkipCapture() async {
    let settings = testSettings()
    settings.setEnabled(.audio, false)
    let providers: [any SensorProvider] = [
        StubProvider(kind: .audio, delay: .milliseconds(1), result: .success(.audio(AudioSample(avg: -40, peak: -20)))),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: settings, timeout: .seconds(1)))
    guard case .disabled = outcomes[.audio] else { Issue.record("expected disabled"); return }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CaptureCoordinatorTests`
Expected: FAIL — `cannot find 'SensorProvider' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Capture/AudioLevel.swift`:

```swift
import Foundation

/// Converts raw AVAudioRecorder dBFS (−160…0) to the original Reporter
/// display scale: display = (raw + 65) × 2 (gist.github.com/dbreunig/9315705).
public enum AudioLevel {
    public static func displayValue(fromRaw raw: Double) -> Double {
        (raw + 65) * 2
    }

    public static func label(forDisplay display: Double) -> String {
        switch display {
        case ..<30: "EXTREMELY QUIET"
        case ..<50: "QUIET"
        case ..<70: "MODERATE"
        case ..<90: "LOUD"
        default: "EXTREMELY LOUD"
        }
    }
}
```

`Sources/DispatchKit/Capture/SensorProvider.swift`:

```swift
import Foundation

public enum SensorPayload: Sendable {
    case location(LocationSnapshot)
    case weather(WeatherObservation)
    case altitude(Double)
    case photos(count: Int, records: [PhotoRecord])
    case audio(AudioSample)
    case battery(Double)
    case connection(Int)
    case focus(FocusState)
    case health([HealthReading])
}

public enum SensorOutcome: Sendable {
    case captured(SensorPayload)
    case unavailable(reason: String)
    case disabled
}

/// One capturable context source. Implementations wrap a system framework
/// (CoreLocation, HealthKit, …) or a mock. capture() may take seconds; the
/// coordinator enforces the timeout.
public protocol SensorProvider: Sendable {
    var kind: SensorKind { get }
    func capture() async throws -> SensorPayload
}

public struct CaptureEvent: Sendable {
    public let kind: SensorKind
    public let outcome: SensorOutcome
    public init(kind: SensorKind, outcome: SensorOutcome) {
        self.kind = kind
        self.outcome = outcome
    }
}
```

`Sources/DispatchKit/Capture/CaptureCoordinator.swift`:

```swift
import Foundation

/// Runs all enabled providers concurrently, each raced against `timeout`.
/// Emits exactly one CaptureEvent per provider; the stream finishes when
/// every provider has resolved. A sensor can time out, throw, or be
/// disabled — none of that stops the others or the report.
public enum CaptureCoordinator {
    public static func capture(
        providers: [any SensorProvider],
        settings: SensorSettings,
        timeout: Duration = .seconds(10)
    ) -> AsyncStream<CaptureEvent> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: CaptureEvent.self) { group in
                    for provider in providers {
                        guard settings.isEnabled(provider.kind) else {
                            continuation.yield(CaptureEvent(kind: provider.kind, outcome: .disabled))
                            continue
                        }
                        group.addTask {
                            await CaptureEvent(kind: provider.kind,
                                               outcome: resolve(provider, timeout: timeout))
                        }
                    }
                    for await event in group {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func resolve(_ provider: any SensorProvider, timeout: Duration) async -> SensorOutcome {
        await withTaskGroup(of: SensorOutcome.self) { group in
            group.addTask {
                do {
                    return .captured(try await provider.capture())
                } catch {
                    return .unavailable(reason: String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable(reason: "timed out")
            }
            let first = await group.next() ?? .unavailable(reason: "no result")
            group.cancelAll()
            return first
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "CaptureCoordinatorTests|AudioLevelTests"`
Expected: PASS (6 tests)

- [ ] **Step 5: Full suite, commit, push**

```bash
swift test && git add Sources/DispatchKit/Capture Tests/DispatchKitTests/CaptureCoordinatorTests.swift Tests/DispatchKitTests/AudioLevelTests.swift
git commit -m "feat: capture coordinator with per-sensor timeouts and audio scale" && git push origin main
```

---

### Task 4: ReportBuilder — outcomes + answers → saved Report

**Files:**
- Create: `Sources/DispatchKit/Capture/ReportBuilder.swift`
- Test: `Tests/DispatchKitTests/ReportBuilderTests.swift`

**Interfaces:**
- Consumes: models, `SensorOutcome`/`SensorPayload` (Task 3), `VocabularyBuilder` (Plan 1).
- Produces:
  - `enum AnswerValue: Equatable, Sendable`: `.tokens([String])`, `.options([String])`, `.number(String)`, `.note(String)`, `.location(text: String)`, `.skipped`
  - `struct AnswerDraft: Sendable { let question: QuestionRef; let value: AnswerValue }` where `QuestionRef` is `(uniqueIdentifier: String, prompt: String, type: QuestionType)` as a small struct.
  - `ReportBuilder.save(kind: ReportKind, trigger: ReportTrigger, date: Date, timeZone: TimeZone, outcomes: [SensorKind: SensorOutcome], answers: [AnswerDraft], in context: ModelContext) throws -> Report` — creates the Report, maps payloads into report fields, creates one Response per non-skipped answer (with `questionIdentifier` + `questionPrompt` set), saves, rebuilds vocabulary.
  - `DispatchStore.lastReportDate(in context: ModelContext) -> Date?` — most recent report date (providers use it for "since last report" windows).
  - SurveyViewModel (Task 5) produces `[AnswerDraft]`; the app flow (Task 9) calls `save`.

- [ ] **Step 1: Write the failing tests**

`Tests/DispatchKitTests/ReportBuilderTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import DispatchKit

private func ref(_ id: String, _ prompt: String, _ type: QuestionType) -> QuestionRef {
    QuestionRef(uniqueIdentifier: id, prompt: prompt, type: type)
}

@Test func savesReportWithSensorsAndAnswers() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let outcomes: [SensorKind: SensorOutcome] = [
        .battery: .captured(.battery(0.42)),
        .audio: .captured(.audio(AudioSample(avg: -50, peak: -30))),
        .altitude: .captured(.altitude(63.0)),
        .connection: .captured(.connection(1)),
        .focus: .captured(.focus(FocusState(label: nil, isFocused: true))),
        .healthSteps: .captured(.health([HealthReading(type: "steps", value: 1200, unit: "count")])),
        .healthHeart: .captured(.health([HealthReading(type: "heartRateAvg", value: 68, unit: "bpm")])),
        .weather: .unavailable(reason: "timed out"),
        .photos: .disabled,
    ]
    let answers: [AnswerDraft] = [
        AnswerDraft(question: ref("q-yesno", "Are you working?", .yesNo), value: .options(["Yes"])),
        AnswerDraft(question: ref("q-tokens", "What are you doing?", .tokens), value: .tokens(["Testing", "Coding"])),
        AnswerDraft(question: ref("q-number", "How many coffees did you have today?", .number), value: .number("2")),
        AnswerDraft(question: ref("q-note", "What did you learn today?", .note), value: .note("ReportBuilder works")),
        AnswerDraft(question: ref("q-location", "Where are you?", .location), value: .location(text: "Home")),
        AnswerDraft(question: ref("q-people", "Who are you with?", .people), value: .skipped),
    ]

    let tz = TimeZone(identifier: "America/New_York")!
    let report = try ReportBuilder.save(kind: .regular, trigger: .manual,
                                        date: Date(timeIntervalSince1970: 1_780_000_000),
                                        timeZone: tz, outcomes: outcomes,
                                        answers: answers, in: context)

    #expect(report.battery == 0.42)
    #expect(report.audio?.avg == -50)
    #expect(report.altitudeMeters == 63.0)
    #expect(report.connectionType == .wifi)
    #expect(report.focus?.isFocused == true)
    #expect(report.weather == nil) // unavailable → absent
    // Two health outcomes merge into one array.
    #expect(Set(report.health.map(\.type)) == ["steps", "heartRateAvg"])
    #expect(report.timeZoneIdentifier == "America/New_York")

    // Skipped answers still record a Response with no payload (v1 semantics).
    #expect(report.responses.count == 6)
    let byPrompt = Dictionary(uniqueKeysWithValues: report.responses.map { ($0.questionPrompt, $0) })
    #expect(byPrompt["Are you working?"]?.answeredOptions == ["Yes"])
    #expect(byPrompt["What are you doing?"]?.tokens?.map(\.text) == ["Testing", "Coding"])
    #expect(byPrompt["How many coffees did you have today?"]?.numericResponse == "2")
    #expect(byPrompt["What did you learn today?"]?.textResponses?.first?.text == "ReportBuilder works")
    #expect(byPrompt["Where are you?"]?.locationResponse?.text == "Home")
    let skipped = try #require(byPrompt["Who are you with?"])
    #expect(skipped.tokens == nil && skipped.answeredOptions == nil)
    #expect(skipped.questionIdentifier == "q-people")

    // Vocabulary rebuilt after save.
    let tokens = try context.fetch(FetchDescriptor<TokenEntity>())
    #expect(Set(tokens.map(\.text)).isSuperset(of: ["Testing", "Coding"]))
}

@Test func lastReportDateReturnsMostRecent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    #expect(DispatchStore.lastReportDate(in: context) == nil)

    let older = Report(); older.date = Date(timeIntervalSince1970: 1_000)
    let newer = Report(); newer.date = Date(timeIntervalSince1970: 2_000)
    context.insert(older); context.insert(newer)
    try context.save()
    #expect(DispatchStore.lastReportDate(in: context) == Date(timeIntervalSince1970: 2_000))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReportBuilderTests`
Expected: FAIL — `cannot find 'QuestionRef' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Capture/ReportBuilder.swift`:

```swift
import Foundation
import SwiftData

public struct QuestionRef: Sendable, Equatable {
    public let uniqueIdentifier: String
    public let prompt: String
    public let type: QuestionType
    public init(uniqueIdentifier: String, prompt: String, type: QuestionType) {
        self.uniqueIdentifier = uniqueIdentifier
        self.prompt = prompt
        self.type = type
    }
}

public enum AnswerValue: Equatable, Sendable {
    case tokens([String])
    case options([String])
    case number(String)
    case note(String)
    case location(text: String)
    case skipped
}

public struct AnswerDraft: Sendable {
    public let question: QuestionRef
    public let value: AnswerValue
    public init(question: QuestionRef, value: AnswerValue) {
        self.question = question
        self.value = value
    }
}

public enum ReportBuilder {
    /// Assembles and saves a Report from capture outcomes and survey answers.
    /// Unavailable/disabled sensors are simply absent from the report.
    /// Every shown question records a Response — payload-less when skipped,
    /// matching the original app's export semantics.
    @discardableResult
    public static func save(
        kind: ReportKind,
        trigger: ReportTrigger,
        date: Date,
        timeZone: TimeZone,
        outcomes: [SensorKind: SensorOutcome],
        answers: [AnswerDraft],
        in context: ModelContext
    ) throws -> Report {
        let report = Report()
        report.date = date
        report.timeZoneIdentifier = timeZone.identifier
        report.kind = kind
        report.trigger = trigger

        var health: [HealthReading] = []
        for outcome in outcomes.values {
            guard case .captured(let payload) = outcome else { continue }
            switch payload {
            case .location(let snapshot): report.location = snapshot
            case .weather(let observation): report.weather = observation
            case .altitude(let meters): report.altitudeMeters = meters
            case .photos(_, let records): report.photos = records
            case .audio(let sample): report.audio = sample
            case .battery(let level): report.battery = level
            case .connection(let raw): report.connection = raw
            case .focus(let state): report.focus = state
            case .health(let readings): health.append(contentsOf: readings)
            }
        }
        report.health = health.sorted { $0.type < $1.type }
        context.insert(report)

        for draft in answers {
            let response = Response()
            response.questionPrompt = draft.question.prompt
            response.questionIdentifier = draft.question.uniqueIdentifier
            switch draft.value {
            case .tokens(let texts):
                response.tokens = texts.map { TokenValue(text: $0) }
            case .options(let options):
                response.answeredOptions = options
            case .number(let number):
                response.numericResponse = number
            case .note(let text):
                response.textResponses = [TokenValue(text: text)]
            case .location(let text):
                var answer = LocationAnswer()
                answer.text = text
                answer.location = report.location
                response.locationResponse = answer
            case .skipped:
                break
            }
            response.report = report
            context.insert(response)
        }

        try context.save()
        try VocabularyBuilder.rebuild(in: context)
        return report
    }
}

public extension DispatchStore {
    static func lastReportDate(in context: ModelContext) -> Date? {
        var descriptor = FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.date
    }
}
```

- [ ] **Step 4: Run to verify pass, then full suite**

Run: `swift test --filter ReportBuilderTests` then `swift test`
Expected: PASS both

- [ ] **Step 5: Commit and push**

```bash
git add Sources/DispatchKit/Capture/ReportBuilder.swift Tests/DispatchKitTests/ReportBuilderTests.swift
git commit -m "feat: report builder assembling sensors, answers, and vocab" && git push origin main
```

---

### Task 5: SurveyViewModel — pagination and answer state

**Files:**
- Create: `Sources/DispatchKit/Capture/SurveyViewModel.swift`
- Test: `Tests/DispatchKitTests/SurveyViewModelTests.swift`

**Interfaces:**
- Consumes: `Question` model, `QuestionRef`/`AnswerValue`/`AnswerDraft` (Task 4).
- Produces: `@Observable public final class SurveyViewModel`:
  - `init(questions: [Question], kind: ReportKind)` — filters enabled + kind, sorts by sortOrder then uniqueIdentifier, snapshots into `[QuestionRef]` + per-question `choices`/`placeholder`.
  - `var pages: [SurveyPage]` where `public struct SurveyPage: Identifiable { public let id: String; public let question: QuestionRef; public let choices: [String]; public let placeholder: String? }`
  - `var currentIndex: Int`, `var isLastPage: Bool`, `func advance()`, `func goBack()`
  - `func answer(_ value: AnswerValue, for id: String)`, `func answerValue(for id: String) -> AnswerValue`
  - `func drafts() -> [AnswerDraft]` — one per page, `.skipped` where unanswered.
  - Yes/No questions get implicit choices `["Yes", "No"]` when `choices` is empty.
  - The survey UI (Task 9) binds to this.

- [ ] **Step 1: Write the failing tests**

`Tests/DispatchKitTests/SurveyViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

private func makeQuestion(_ id: String, _ prompt: String, _ type: QuestionType,
                          sort: Int, enabled: Bool = true,
                          kinds: [ReportKind] = [.regular], choices: [String] = []) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.sortOrder = sort
    question.isEnabled = enabled
    question.reportKinds = kinds
    question.choices = choices
    return question
}

@Test func filtersAndOrdersQuestions() {
    let questions = [
        makeQuestion("q3", "Third?", .note, sort: 3),
        makeQuestion("q1", "First?", .yesNo, sort: 1),
        makeQuestion("q-off", "Disabled?", .yesNo, sort: 0, enabled: false),
        makeQuestion("q-wake", "How did you sleep?", .multipleChoice, sort: 2, kinds: [.wake]),
        makeQuestion("q2", "Second?", .tokens, sort: 2),
    ]
    let viewModel = SurveyViewModel(questions: questions, kind: .regular)
    #expect(viewModel.pages.map(\.id) == ["q1", "q2", "q3"])

    let wakeViewModel = SurveyViewModel(questions: questions, kind: .wake)
    #expect(wakeViewModel.pages.map(\.id) == ["q-wake"])
}

@Test func yesNoGetsImplicitChoices() {
    let viewModel = SurveyViewModel(questions: [makeQuestion("q1", "Working?", .yesNo, sort: 0)], kind: .regular)
    #expect(viewModel.pages[0].choices == ["Yes", "No"])
}

@Test func navigationAndAnswers() {
    let questions = [
        makeQuestion("q1", "Working?", .yesNo, sort: 0),
        makeQuestion("q2", "Doing?", .tokens, sort: 1),
    ]
    let viewModel = SurveyViewModel(questions: questions, kind: .regular)
    #expect(viewModel.currentIndex == 0)
    #expect(!viewModel.isLastPage)
    viewModel.answer(.options(["Yes"]), for: "q1")
    viewModel.advance()
    #expect(viewModel.isLastPage)
    viewModel.advance() // clamps
    #expect(viewModel.currentIndex == 1)
    viewModel.goBack()
    #expect(viewModel.currentIndex == 0)
    #expect(viewModel.answerValue(for: "q1") == .options(["Yes"]))

    let drafts = viewModel.drafts()
    #expect(drafts.count == 2)
    #expect(drafts[0].value == .options(["Yes"]))
    #expect(drafts[1].value == .skipped)
    #expect(drafts[1].question.uniqueIdentifier == "q2")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SurveyViewModelTests`
Expected: FAIL — `cannot find 'SurveyViewModel' in scope`

- [ ] **Step 3: Implement**

`Sources/DispatchKit/Capture/SurveyViewModel.swift`:

```swift
import Foundation
import Observation

public struct SurveyPage: Identifiable, Sendable {
    public let id: String
    public let question: QuestionRef
    public let choices: [String]
    public let placeholder: String?
}

/// Drives the paged survey: question filtering/ordering, current page,
/// and per-question answer state. UI-framework-free for testability.
@Observable
public final class SurveyViewModel {
    public private(set) var pages: [SurveyPage]
    public private(set) var currentIndex = 0
    private var answers: [String: AnswerValue] = [:]

    public init(questions: [Question], kind: ReportKind) {
        pages = questions
            .filter { $0.isEnabled && $0.reportKinds.contains(kind) }
            .sorted {
                ($0.sortOrder, $0.uniqueIdentifier) < ($1.sortOrder, $1.uniqueIdentifier)
            }
            .map { question in
                var choices = question.choices
                if question.type == .yesNo && choices.isEmpty {
                    choices = ["Yes", "No"]
                }
                return SurveyPage(
                    id: question.uniqueIdentifier,
                    question: QuestionRef(uniqueIdentifier: question.uniqueIdentifier,
                                          prompt: question.prompt,
                                          type: question.type),
                    choices: choices,
                    placeholder: question.placeholderString)
            }
    }

    public var isLastPage: Bool { currentIndex >= pages.count - 1 }

    public func advance() {
        currentIndex = min(currentIndex + 1, max(pages.count - 1, 0))
    }

    public func goBack() {
        currentIndex = max(currentIndex - 1, 0)
    }

    public func answer(_ value: AnswerValue, for id: String) {
        answers[id] = value
    }

    public func answerValue(for id: String) -> AnswerValue {
        answers[id] ?? .skipped
    }

    public func drafts() -> [AnswerDraft] {
        pages.map { AnswerDraft(question: $0.question, value: answerValue(for: $0.id)) }
    }
}
```

- [ ] **Step 4: Run to verify pass, full suite**

Run: `swift test --filter SurveyViewModelTests` then `swift test`
Expected: PASS both

- [ ] **Step 5: Commit and push**

```bash
git add Sources/DispatchKit/Capture/SurveyViewModel.swift Tests/DispatchKitTests/SurveyViewModelTests.swift
git commit -m "feat: survey view model with kind filtering and answer state" && git push origin main
```

---

### Task 6: App providers wave 1 — battery, connection, audio, photos

**Files:**
- Create: `App/Sources/Providers/BatteryProvider.swift`
- Create: `App/Sources/Providers/ConnectionProvider.swift`
- Create: `App/Sources/Providers/AudioProvider.swift`
- Create: `App/Sources/Providers/PhotosProvider.swift`
- Modify: `project.yml` (purpose strings)

**Interfaces:**
- Consumes: `SensorProvider`/`SensorPayload` (Task 3), `DispatchStore.lastReportDate` (Task 4).
- Produces: four concrete `SensorProvider` implementations the flow (Task 9) composes. Not unit-tested (system frameworks); verified by build + on-device smoke; the XCUITest (Task 10) uses mocks instead.

- [ ] **Step 1: Implement the providers**

`App/Sources/Providers/BatteryProvider.swift`:

```swift
import DispatchKit
import UIKit

struct BatteryProvider: SensorProvider {
    let kind = SensorKind.battery

    func capture() async throws -> SensorPayload {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let level = await MainActor.run { UIDevice.current.batteryLevel }
        guard level >= 0 else {
            throw ProviderError("battery level unavailable")
        }
        return .battery(Double(level))
    }
}

struct ProviderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
```

`App/Sources/Providers/ConnectionProvider.swift`:

```swift
import DispatchKit
import Network

struct ConnectionProvider: SensorProvider {
    let kind = SensorKind.connection

    func capture() async throws -> SensorPayload {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let path = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "connection-probe"))
        }
        guard path.status == .satisfied else { return .connection(ConnectionType.none.rawValue) }
        let type: ConnectionType = path.usesInterfaceType(.wifi) ? .wifi : .cellular
        return .connection(type.rawValue)
    }
}
```

`App/Sources/Providers/AudioProvider.swift`:

```swift
import AVFAudio
import DispatchKit
import Foundation

/// Samples ambient audio for ~2 seconds via AVAudioRecorder metering and
/// reports average/peak dBFS (raw −160…0; display conversion is
/// AudioLevel.displayValue).
struct AudioProvider: SensorProvider {
    let kind = SensorKind.audio

    func capture() async throws -> SensorPayload {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw ProviderError("microphone permission denied")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-audio-probe.m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
        ])
        recorder.isMeteringEnabled = true
        recorder.record()
        defer {
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
        }

        var averages: [Double] = []
        var peaks: [Double] = []
        for _ in 0..<8 { // 8 × 250 ms = 2 s
            try await Task.sleep(for: .milliseconds(250))
            recorder.updateMeters()
            averages.append(Double(recorder.averagePower(forChannel: 0)))
            peaks.append(Double(recorder.peakPower(forChannel: 0)))
        }
        let avg = averages.reduce(0, +) / Double(averages.count)
        let peak = peaks.max() ?? avg
        return .audio(AudioSample(avg: avg, peak: peak))
    }
}
```

`App/Sources/Providers/PhotosProvider.swift`:

```swift
import DispatchKit
import Foundation
import Photos

/// Counts photos taken since the last report (falls back to start of today).
struct PhotosProvider: SensorProvider {
    let kind = SensorKind.photos
    let since: Date?

    func capture() async throws -> SensorPayload {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ProviderError("photo library permission denied")
        }
        let cutoff = since ?? Calendar.current.startOfDay(for: Date())
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d",
                                        cutoff as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        var records: [PhotoRecord] = []
        assets.enumerateObjects { asset, _, _ in
            var record = PhotoRecord(uniqueIdentifier: asset.localIdentifier)
            record.pixelWidth = asset.pixelWidth
            record.pixelHeight = asset.pixelHeight
            record.dateTime = asset.creationDate
            record.latitude = asset.location?.coordinate.latitude
            record.longitude = asset.location?.coordinate.longitude
            records.append(record)
        }
        return .photos(count: records.count, records: records)
    }
}
```

- [ ] **Step 2: Add purpose strings to project.yml**

In `project.yml` under `targets.DispatchApp.settings.base`, add:

```yaml
        INFOPLIST_KEY_NSMicrophoneUsageDescription: "Dispatch samples the ambient sound level (a decibel number only, no recording is kept) when you file a report."
        INFOPLIST_KEY_NSPhotoLibraryUsageDescription: "Dispatch counts how many photos you took since your last report."
```

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -2`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Full DispatchKit suite still green**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit and push**

```bash
git add App/Sources/Providers project.yml
git commit -m "feat: battery, connection, audio, photos providers" && git push origin main
```

---

### Task 7: App providers wave 2 — location + altitude + weather

**Files:**
- Create: `App/Sources/Providers/LocationProvider.swift`
- Create: `App/Sources/Providers/WeatherProvider.swift`
- Modify: `project.yml` (location purpose string, WeatherKit entitlement)
- Create: `App/Dispatch.entitlements`

**Interfaces:**
- Consumes: `SensorProvider` (Task 3), value structs.
- Produces: `LocationProvider` (one-shot location + CLGeocoder placemark → `.location(LocationSnapshot)`; also exposes `lastFix: CLLocation?` via an actor for reuse), `AltitudeFromLocationProvider` (reads the fix → `.altitude`), `WeatherProvider` (WeatherKit → `.weather(WeatherObservation)`, gracefully unavailable without entitlement/network). Composed in Task 9.

- [ ] **Step 1: Implement location + altitude**

`App/Sources/Providers/LocationProvider.swift`:

```swift
import CoreLocation
import DispatchKit
import Foundation

/// Shares the CLLocation fix between the location, altitude, and weather
/// providers so one report takes one GPS fix.
actor LocationFixStore {
    static let shared = LocationFixStore()
    private(set) var lastFix: CLLocation?
    func store(_ fix: CLLocation) { lastFix = fix }
}

final class LocationProvider: NSObject, SensorProvider, CLLocationManagerDelegate, @unchecked Sendable {
    let kind = SensorKind.location
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func capture() async throws -> SensorPayload {
        let fix = try await requestFix()
        await LocationFixStore.shared.store(fix)
        var snapshot = LocationSnapshot(latitude: fix.coordinate.latitude,
                                        longitude: fix.coordinate.longitude)
        snapshot.altitude = fix.altitude
        snapshot.horizontalAccuracy = fix.horizontalAccuracy
        snapshot.verticalAccuracy = fix.verticalAccuracy
        snapshot.speed = fix.speed
        snapshot.course = fix.course
        snapshot.timestamp = fix.timestamp
        if let clPlacemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first {
            var placemark = Placemark()
            placemark.name = clPlacemark.name
            placemark.thoroughfare = clPlacemark.thoroughfare
            placemark.subThoroughfare = clPlacemark.subThoroughfare
            placemark.locality = clPlacemark.locality
            placemark.subLocality = clPlacemark.subLocality
            placemark.administrativeArea = clPlacemark.administrativeArea
            placemark.subAdministrativeArea = clPlacemark.subAdministrativeArea
            placemark.postalCode = clPlacemark.postalCode
            placemark.country = clPlacemark.country
            snapshot.placemark = placemark
        }
        return .location(snapshot)
    }

    private func requestFix() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last {
            continuation?.resume(returning: fix)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct AltitudeFromLocationProvider: SensorProvider {
    let kind = SensorKind.altitude

    func capture() async throws -> SensorPayload {
        // Location provider runs concurrently; wait briefly for its fix.
        for _ in 0..<20 {
            if let fix = await LocationFixStore.shared.lastFix {
                return .altitude(fix.altitude)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw ProviderError("no location fix for altitude")
    }
}
```

- [ ] **Step 2: Implement weather**

`App/Sources/Providers/WeatherProvider.swift`:

```swift
import CoreLocation
import DispatchKit
import Foundation
import WeatherKit

/// WeatherKit current conditions at the report's location. Degrades to
/// unavailable when the entitlement, network, or fix is missing.
struct WeatherProvider: SensorProvider {
    let kind = SensorKind.weather

    func capture() async throws -> SensorPayload {
        var fix: CLLocation?
        for _ in 0..<20 {
            fix = await LocationFixStore.shared.lastFix
            if fix != nil { break }
            try await Task.sleep(for: .milliseconds(400))
        }
        guard let location = fix else { throw ProviderError("no location fix for weather") }

        let current = try await WeatherService.shared.weather(for: location, including: .current)
        var observation = WeatherObservation()
        observation.tempF = current.temperature.converted(to: .fahrenheit).value
        observation.tempC = current.temperature.converted(to: .celsius).value
        observation.feelslikeF = current.apparentTemperature.converted(to: .fahrenheit).value
        observation.feelslikeC = current.apparentTemperature.converted(to: .celsius).value
        observation.condition = current.condition.description
        observation.relativeHumidity = "\(Int(current.humidity * 100))%"
        observation.windMPH = current.wind.speed.converted(to: .milesPerHour).value
        observation.windKPH = current.wind.speed.converted(to: .kilometersPerHour).value
        observation.windGustMPH = current.wind.gust?.converted(to: .milesPerHour).value
        observation.windGustKPH = current.wind.gust?.converted(to: .kilometersPerHour).value
        observation.windDegrees = current.wind.direction.converted(to: .degrees).value
        observation.pressureIn = current.pressure.converted(to: .inchesOfMercury).value
        observation.pressureMb = current.pressure.converted(to: .millibars).value
        observation.visibilityMi = current.visibility.converted(to: .miles).value
        observation.visibilityKM = current.visibility.converted(to: .kilometers).value
        observation.dewpointC = current.dewPoint.converted(to: .celsius).value
        observation.uv = Double(current.uvIndex.value)
        return .weather(observation)
    }
}
```

- [ ] **Step 3: Entitlements + purpose string**

`App/Dispatch.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.weatherkit</key>
    <true/>
</dict>
</plist>
```

In `project.yml` under `targets.DispatchApp.settings.base` add:

```yaml
        CODE_SIGN_ENTITLEMENTS: App/Dispatch.entitlements
        INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: "Dispatch records where you are when you file a report."
```

- [ ] **Step 4: Regenerate, build, full suite**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -2 && swift test`
Expected: `BUILD SUCCEEDED`, tests PASS. If code-signing rejects the WeatherKit entitlement for simulator builds, set `CODE_SIGNING_ALLOWED: "NO"` is NOT the fix — instead scope the entitlement under a `configs`-conditional or note the signing behavior observed in your report; simulator builds normally accept entitlements without a paid account.

- [ ] **Step 5: Commit and push**

```bash
git add App/Sources/Providers App/Dispatch.entitlements project.yml
git commit -m "feat: location, altitude, and WeatherKit providers" && git push origin main
```

---

### Task 8: App providers wave 3 — HealthKit hub + Focus boolean

**Files:**
- Create: `App/Sources/Providers/HealthProviders.swift`
- Create: `App/Sources/Providers/FocusProvider.swift`
- Modify: `App/Dispatch.entitlements` (HealthKit)
- Modify: `project.yml` (health purpose string)

**Interfaces:**
- Consumes: `SensorProvider`, `HealthReading`, `DispatchStore.lastReportDate` window (passed in as `since: Date?`).
- Produces: `HealthHubProvider` — ONE provider per health SensorKind, built from a shared `HealthKitReader`; `FocusProvider` (INFocusStatusCenter boolean). Composed in Task 9.

- [ ] **Step 1: Implement the health providers**

`App/Sources/Providers/HealthProviders.swift`:

```swift
import DispatchKit
import Foundation
import HealthKit

/// Shared HealthKit access for all health sensor providers.
final class HealthKitReader: Sendable {
    let store = HKHealthStore()

    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount), HKQuantityType(.flightsClimbed),
        HKQuantityType(.heartRate), HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.restingHeartRate), HKQuantityType(.dietaryCaffeine),
        HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(),
    ]

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ProviderError("health data unavailable on this device")
        }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, since: Date) async throws -> Double {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit, since: Date) async throws -> Double? {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> (value: Double, date: Date)? {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (sample.quantity.doubleValue(for: unit), sample.endDate))
            }
            store.execute(query)
        }
    }

    func sleepSeconds(sinceYesterdayEvening now: Date) async throws -> [String: Double] {
        let start = Calendar.current.date(byAdding: .hour, value: -18,
                                          to: Calendar.current.startOfDay(for: now))!
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                var byStage: [String: Double] = [:]
                for case let sample as HKCategorySample in samples ?? [] {
                    guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                          HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage) else { continue }
                    let key: String = switch stage {
                    case .asleepDeep: "sleepDeep"
                    case .asleepREM: "sleepREM"
                    case .asleepCore: "sleepCore"
                    default: "sleepUnspecified"
                    }
                    byStage[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                }
                continuation.resume(returning: byStage)
            }
            store.execute(query)
        }
    }

    func workoutsToday(now: Date) async throws -> [HealthReading] {
        let start = Calendar.current.startOfDay(for: now)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let readings = (samples ?? []).compactMap { sample -> HealthReading? in
                    guard let workout = sample as? HKWorkout else { return nil }
                    return HealthReading(type: "workout.\(workout.workoutActivityType.rawValue)",
                                         value: workout.duration, unit: "s",
                                         startDate: workout.startDate, endDate: workout.endDate)
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }
}

/// One SensorProvider per health metric so each is independently
/// toggleable and independently timeout-raced.
struct HealthMetricProvider: SensorProvider {
    let kind: SensorKind
    let reader: HealthKitReader
    let since: Date?

    func capture() async throws -> SensorPayload {
        try await reader.authorize()
        let now = Date()
        let window = since ?? Calendar.current.startOfDay(for: now)
        switch kind {
        case .healthSteps:
            let steps = try await reader.sum(.stepCount, unit: .count(), since: window)
            return .health([HealthReading(type: "steps", value: steps, unit: "count",
                                          startDate: window, endDate: now)])
        case .healthFlights:
            let flights = try await reader.sum(.flightsClimbed, unit: .count(), since: window)
            return .health([HealthReading(type: "flightsClimbed", value: flights, unit: "count",
                                          startDate: window, endDate: now)])
        case .healthHeart:
            var readings: [HealthReading] = []
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if let avg = try await reader.average(.heartRate, unit: bpm, since: window) {
                readings.append(HealthReading(type: "heartRateAvg", value: avg, unit: "bpm",
                                              startDate: window, endDate: now))
            }
            if let latest = try await reader.latest(.heartRate, unit: bpm) {
                readings.append(HealthReading(type: "heartRateLatest", value: latest.value, unit: "bpm",
                                              endDate: latest.date))
            }
            guard !readings.isEmpty else { throw ProviderError("no heart rate samples") }
            return .health(readings)
        case .healthHRV:
            guard let latest = try await reader.latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)) else {
                throw ProviderError("no HRV samples")
            }
            return .health([HealthReading(type: "hrvSDNN", value: latest.value, unit: "ms", endDate: latest.date)])
        case .healthRestingHeart:
            guard let latest = try await reader.latest(.restingHeartRate,
                                                       unit: .count().unitDivided(by: .minute())) else {
                throw ProviderError("no resting heart rate samples")
            }
            return .health([HealthReading(type: "restingHeartRate", value: latest.value, unit: "bpm",
                                          endDate: latest.date)])
        case .healthCaffeine:
            let mg = try await reader.sum(.dietaryCaffeine, unit: .gramUnit(with: .milli),
                                          since: Calendar.current.startOfDay(for: now))
            return .health([HealthReading(type: "caffeine", value: mg, unit: "mg", endDate: now)])
        case .healthSleep:
            let stages = try await reader.sleepSeconds(sinceYesterdayEvening: now)
            guard !stages.isEmpty else { throw ProviderError("no sleep samples") }
            return .health(stages.map { HealthReading(type: $0.key, value: $0.value, unit: "s") }
                .sorted { $0.type < $1.type })
        case .healthWorkouts:
            let workouts = try await reader.workoutsToday(now: now)
            return .health(workouts)
        default:
            throw ProviderError("not a health metric: \(kind.rawValue)")
        }
    }
}
```

Medications: after writing the above, check the iOS 26 SDK for a public medications read API (`HKMedicationDoseEvent` or similar in HealthKit). If present, add a `.healthMedications` case mirroring the pattern (today's dose events → `HealthReading(type: "medicationDose.<concept>", value: 1, unit: "dose")`) and request its read type in `readTypes`. If absent, leave `.healthMedications` falling into the `default:` throw and state in your report that the SDK lacks the API.

- [ ] **Step 2: Implement the Focus provider**

`App/Sources/Providers/FocusProvider.swift`:

```swift
import DispatchKit
import Foundation
import Intents

/// Captures whether a Focus is active (boolean only — per-Focus labels
/// arrive with the Focus Filter extension in Plan 4).
struct FocusProvider: SensorProvider {
    let kind = SensorKind.focus

    func capture() async throws -> SensorPayload {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                center.requestAuthorization { status in continuation.resume(returning: status) }
            }
        }
        guard center.authorizationStatus == .authorized else {
            throw ProviderError("focus status not authorized")
        }
        guard let isFocused = center.focusStatus.isFocused else {
            throw ProviderError("focus status unavailable")
        }
        return .focus(FocusState(label: nil, isFocused: isFocused))
    }
}
```

- [ ] **Step 3: Entitlements + purpose strings**

Add to `App/Dispatch.entitlements` inside the `<dict>`:

```xml
    <key>com.apple.developer.healthkit</key>
    <true/>
    <key>com.apple.developer.healthkit.access</key>
    <array/>
```

Add to `project.yml` settings:

```yaml
        INFOPLIST_KEY_NSHealthShareUsageDescription: "Dispatch reads steps, flights, heart rate, HRV, sleep, workouts, and caffeine to add context to your reports."
        INFOPLIST_KEY_NSFocusStatusUsageDescription: "Dispatch records whether a Focus is on when you file a report."
```

- [ ] **Step 4: Regenerate, build, full suite**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -2 && swift test`
Expected: `BUILD SUCCEEDED`, tests PASS

- [ ] **Step 5: Commit and push**

```bash
git add App/Sources/Providers App/Dispatch.entitlements project.yml
git commit -m "feat: HealthKit hub and Focus status providers" && git push origin main
```

---

### Task 9: Survey flow UI

**Files:**
- Create: `App/Sources/Survey/CaptureChecklistView.swift`
- Create: `App/Sources/Survey/QuestionPageView.swift`
- Create: `App/Sources/Survey/SurveyFlowView.swift`
- Create: `App/Sources/Survey/SurveyController.swift`
- Modify: `App/Sources/ContentView.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8: CaptureCoordinator stream, SurveyViewModel, ReportBuilder, all providers, SensorSettings.
- Produces: `SurveyFlowView(kind:trigger:)` presented full-screen from ContentView's REPORT button; `SurveyController` (@Observable, @MainActor) that owns the capture stream state + view model and performs the final save. `MockProviders.all` used when launch arguments contain `--mock-sensors` (XCUITest hook, Task 10).

- [ ] **Step 1: Implement the survey controller**

`App/Sources/Survey/SurveyController.swift`:

```swift
import DispatchKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SurveyController {
    let survey: SurveyViewModel
    private(set) var outcomes: [SensorKind: SensorOutcome] = [:]
    private(set) var captureFinished = false
    private let kind: ReportKind
    private let trigger: ReportTrigger
    private let settings = SensorSettings()

    init(questions: [Question], kind: ReportKind, trigger: ReportTrigger) {
        self.survey = SurveyViewModel(questions: questions, kind: kind)
        self.kind = kind
        self.trigger = trigger
    }

    static func providers(since: Date?) -> [any SensorProvider] {
        if ProcessInfo.processInfo.arguments.contains("--mock-sensors") {
            return MockProviders.all
        }
        let health = HealthKitReader()
        return [
            LocationProvider(), AltitudeFromLocationProvider(), WeatherProvider(),
            BatteryProvider(), ConnectionProvider(), AudioProvider(),
            PhotosProvider(since: since), FocusProvider(),
            HealthMetricProvider(kind: .healthSteps, reader: health, since: since),
            HealthMetricProvider(kind: .healthFlights, reader: health, since: since),
            HealthMetricProvider(kind: .healthHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthHRV, reader: health, since: since),
            HealthMetricProvider(kind: .healthRestingHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthSleep, reader: health, since: since),
            HealthMetricProvider(kind: .healthWorkouts, reader: health, since: since),
            HealthMetricProvider(kind: .healthCaffeine, reader: health, since: since),
        ]
    }

    func startCapture(since: Date?) async {
        let stream = CaptureCoordinator.capture(providers: Self.providers(since: since),
                                                settings: settings)
        for await event in stream {
            outcomes[event.kind] = event.outcome
        }
        captureFinished = true
    }

    func save(in context: ModelContext) throws {
        try ReportBuilder.save(kind: kind, trigger: trigger, date: Date(),
                               timeZone: TimeZone.current, outcomes: outcomes,
                               answers: survey.drafts(), in: context)
    }
}

/// Deterministic providers for XCUITest (--mock-sensors).
enum MockProviders {
    static let all: [any SensorProvider] = [
        Mock(kind: .battery, payload: .battery(0.8)),
        Mock(kind: .audio, payload: .audio(AudioSample(avg: -52.8, peak: -40))),
        Mock(kind: .altitude, payload: .altitude(63)),
        Mock(kind: .connection, payload: .connection(1)),
        Mock(kind: .healthSteps, payload: .health([HealthReading(type: "steps", value: 27851, unit: "count")])),
    ]

    struct Mock: SensorProvider {
        let kind: SensorKind
        let payload: SensorPayload
        func capture() async throws -> SensorPayload { payload }
    }
}
```

- [ ] **Step 2: Implement the checklist and question pages**

`App/Sources/Survey/CaptureChecklistView.swift`:

```swift
import DispatchKit
import SwiftUI

struct CaptureChecklistView: View {
    let outcomes: [SensorKind: SensorOutcome]

    private static let rows: [(SensorKind, String, String)] = [
        (.location, "mappin", "LOCATION"),
        (.weather, "cloud.fill", "WEATHER CONDITIONS"),
        (.altitude, "mountain.2.fill", "ALTITUDE"),
        (.photos, "camera.fill", "PHOTOS"),
        (.audio, "mic.fill", "AUDIO"),
        (.healthSteps, "figure.walk", "STEPS"),
        (.healthFlights, "stairs", "STAIRS"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.rows, id: \.0) { kind, icon, label in
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 24)
                    Text(text(for: kind, label: label))
                        .font(.subheadline.weight(.semibold))
                        .kerning(1.2)
                }
                .opacity(outcomes[kind] == nil ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func text(for kind: SensorKind, label: String) -> String {
        switch outcomes[kind] {
        case nil: "GETTING \(label)…"
        case .disabled: "\(label) OFF"
        case .unavailable: "UNABLE TO DETECT \(label)"
        case .captured(let payload): captured(payload, label: label)
        }
    }

    private func captured(_ payload: SensorPayload, label: String) -> String {
        switch payload {
        case .location(let snapshot):
            let place = [snapshot.placemark?.locality, snapshot.placemark?.administrativeArea]
                .compactMap(\.self).joined(separator: ", ")
            return place.isEmpty ? "LOCATION CAPTURED" : place.uppercased()
        case .weather(let observation):
            return (observation.condition ?? "WEATHER CAPTURED").uppercased()
        case .altitude(let meters):
            return "\(Int(meters * 3.28084)) FEET"
        case .photos(let count, _):
            return "\(count) PHOTOS ADDED"
        case .audio(let sample):
            let display = AudioLevel.displayValue(fromRaw: sample.avg)
            return "\(AudioLevel.label(forDisplay: display)) \(String(format: "%.2f", display)) DB"
        case .health(let readings):
            if let steps = readings.first(where: { $0.type == "steps" }) {
                return "\(Int(steps.value).formatted()) STEPS TAKEN"
            }
            if let flights = readings.first(where: { $0.type == "flightsClimbed" }) {
                return "\(Int(flights.value)) STAIRCASES"
            }
            return "\(label) CAPTURED"
        case .battery, .connection, .focus:
            return "\(label) CAPTURED"
        }
    }
}
```

`App/Sources/Survey/QuestionPageView.swift`:

```swift
import DispatchKit
import SwiftUI

struct QuestionPageView: View {
    let page: SurveyPage
    let value: AnswerValue
    let onAnswer: (AnswerValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.question.prompt.uppercased())
                .font(.subheadline.weight(.semibold))
                .kerning(1.2)
                .padding(.horizontal)
                .padding(.bottom, 8)
            Divider()
            answerBody
            Spacer()
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        switch page.question.type {
        case .yesNo, .multipleChoice:
            ChoiceListView(choices: page.choices,
                           multiSelect: page.question.type == .multipleChoice,
                           selected: selectedOptions,
                           onSelect: { onAnswer(.options($0)) })
        case .tokens, .people:
            TokenEntryView(placeholder: page.placeholder ?? "Add…",
                           tokens: currentTokens,
                           onChange: { onAnswer(.tokens($0)) })
        case .number:
            TextField(page.placeholder ?? "0", text: numberBinding)
                .keyboardType(.decimalPad)
                .font(.title2)
                .padding()
                .accessibilityIdentifier("number-field")
        case .note:
            TextEditor(text: noteBinding)
                .frame(minHeight: 160)
                .padding(.horizontal)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("note-editor")
        case .location:
            TextField(page.placeholder ?? "Where are you?", text: locationBinding)
                .font(.title2)
                .padding()
                .accessibilityIdentifier("location-field")
        }
    }

    private var selectedOptions: [String] {
        if case .options(let options) = value { return options }
        return []
    }

    private var currentTokens: [String] {
        if case .tokens(let tokens) = value { return tokens }
        return []
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { if case .number(let number) = value { number } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .number($0)) })
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { if case .note(let note) = value { note } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .note($0)) })
    }

    private var locationBinding: Binding<String> {
        Binding(
            get: { if case .location(let text) = value { text } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .location(text: $0)) })
    }
}

struct ChoiceListView: View {
    let choices: [String]
    let multiSelect: Bool
    let selected: [String]
    let onSelect: ([String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    toggle(choice)
                } label: {
                    HStack {
                        Text(choice).font(.title3)
                        Spacer()
                        if selected.contains(choice) {
                            Image(systemName: "checkmark")
                        }
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(selected.isEmpty || selected.contains(choice) ? 1 : 0.5)
                Divider()
            }
        }
    }

    private func toggle(_ choice: String) {
        if multiSelect {
            var next = selected
            if let index = next.firstIndex(of: choice) { next.remove(at: index) } else { next.append(choice) }
            onSelect(next)
        } else {
            onSelect(selected == [choice] ? [] : [choice])
        }
    }
}

struct TokenEntryView: View {
    let placeholder: String
    let tokens: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !tokens.isEmpty {
                FlowingChips(tokens: tokens) { removed in
                    onChange(tokens.filter { $0 != removed })
                }
            }
            TextField(placeholder, text: $draft)
                .font(.title3)
                .onSubmit {
                    let trimmed = draft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onChange(tokens + [trimmed])
                    draft = ""
                }
                .accessibilityIdentifier("token-field")
        }
        .padding()
    }
}

struct FlowingChips: View {
    let tokens: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tokens, id: \.self) { token in
                    Button {
                        onRemove(token)
                    } label: {
                        HStack(spacing: 4) {
                            Text(token)
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Implement the flow container and wire ContentView**

`App/Sources/Survey/SurveyFlowView.swift`:

```swift
import DispatchKit
import SwiftData
import SwiftUI

struct SurveyFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var questions: [Question]
    @State private var controller: SurveyController?
    let kind: ReportKind
    let trigger: ReportTrigger

    var body: some View {
        Group {
            if let controller {
                flow(controller)
            } else {
                ProgressView()
            }
        }
        .task {
            guard controller == nil else { return }
            let newController = SurveyController(questions: questions, kind: kind, trigger: trigger)
            controller = newController
            await newController.startCapture(since: DispatchStore.lastReportDate(in: modelContext))
        }
    }

    @ViewBuilder
    private func flow(_ controller: SurveyController) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(controller.survey.currentIndex + 1),
                         total: Double(max(controller.survey.pages.count, 1)))
                .padding()
                .accessibilityIdentifier("survey-progress")

            TabView(selection: Binding(
                get: { controller.survey.currentIndex },
                set: { _ in })) {
                ForEach(Array(controller.survey.pages.enumerated()), id: \.element.id) { index, page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if index == 0 {
                                CaptureChecklistView(outcomes: controller.outcomes)
                                    .padding(.top)
                            }
                            QuestionPageView(page: page,
                                             value: controller.survey.answerValue(for: page.id),
                                             onAnswer: { controller.survey.answer($0, for: page.id) })
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Button("CANCEL") { dismiss() }
                    .accessibilityIdentifier("survey-cancel")
                Spacer()
                Text("\(controller.survey.currentIndex + 1) / \(max(controller.survey.pages.count, 1))")
                    .font(.footnote)
                Spacer()
                Button(controller.survey.isLastPage ? "DONE" : "NEXT") {
                    if controller.survey.isLastPage {
                        try? controller.save(in: modelContext)
                        dismiss()
                    } else {
                        controller.survey.advance()
                    }
                }
                .accessibilityIdentifier("survey-next")
            }
            .font(.subheadline.weight(.semibold))
            .padding()
        }
        .background(Color(red: 0.98, green: 0.36, blue: 0.22).opacity(0.12))
    }
}
```

Replace `App/Sources/ContentView.swift`:

```swift
import DispatchKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Query private var reports: [Report]
    @State private var showingSurvey = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "hexagon.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white.opacity(0.35))
            Text("\(reports.count) reports")
                .font(.subheadline)
                .foregroundStyle(.white)
                .accessibilityIdentifier("report-count")
            Spacer()
            HStack {
                Button("REPORT") { showingSurvey = true }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("report-button")
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.98, green: 0.36, blue: 0.22))
        .fullScreenCover(isPresented: $showingSurvey) {
            SurveyFlowView(kind: .regular, trigger: .manual)
        }
    }
}
```

- [ ] **Step 4: Seed default questions on first launch**

In `App/Sources/DispatchApp.swift`, replace the file with:

```swift
import DispatchKit
import SwiftData
import SwiftUI

@main
struct DispatchApp: App {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: Schema(DispatchStore.allModels))
        seedDefaultQuestionsIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    private func seedDefaultQuestionsIfNeeded() {
        let context = ModelContext(container)
        guard ((try? context.fetchCount(FetchDescriptor<Question>())) ?? 0) == 0 else { return }
        let defaults: [(String, QuestionType)] = [
            ("How did you sleep?", .multipleChoice),
            ("Are you working?", .yesNo),
            ("What are you doing?", .tokens),
            ("Where are you?", .location),
            ("Who are you with?", .people),
            ("How many coffees did you have today?", .number),
            ("What did you learn today?", .note),
        ]
        for (index, (prompt, type)) in defaults.enumerated() {
            let question = Question()
            question.uniqueIdentifier = "default-question-\(index)"
            question.prompt = prompt
            question.type = type
            question.sortOrder = index
            if prompt == "How did you sleep?" {
                question.reportKinds = [.wake]
                question.choices = ["Great", "OK", "Poorly"]
            }
            context.insert(question)
        }
        try? context.save()
    }
}
```

- [ ] **Step 5: Regenerate, build, full suite**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -2 && swift test`
Expected: `BUILD SUCCEEDED`, tests PASS

- [ ] **Step 6: Commit and push**

```bash
git add App/Sources
git commit -m "feat: survey flow UI with capture checklist and 7 question types" && git push origin main
```

---

### Task 10: XCUITest smoke — full report flow with mocks

**Files:**
- Create: `AppUITests/SurveyFlowUITests.swift`
- Modify: `project.yml` (UI test target)

**Interfaces:**
- Consumes: `--mock-sensors` hook (Task 9), accessibility identifiers set in Task 9.
- Produces: an end-to-end proof the flow saves a report.

- [ ] **Step 1: Add the UI test target to project.yml**

Append under `targets:`:

```yaml
  DispatchUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [AppUITests]
    dependencies:
      - target: DispatchApp
    settings:
      base:
        TEST_TARGET_NAME: DispatchApp
        PRODUCT_BUNDLE_IDENTIFIER: com.robbiet480.dispatch.uitests
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: 6.0
```

And add a scheme so `xcodebuild test` finds it:

```yaml
schemes:
  DispatchApp:
    build:
      targets:
        DispatchApp: all
        DispatchUITests: [test]
    test:
      targets: [DispatchUITests]
```

- [ ] **Step 2: Write the UI test**

`AppUITests/SurveyFlowUITests.swift`:

```swift
import XCTest

final class SurveyFlowUITests: XCTestCase {
    @MainActor
    func testCompleteReportFlowSavesReport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mock-sensors"]
        app.launch()

        let countLabel = app.staticTexts["report-count"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        let before = countLabel.label // e.g. "0 reports"

        app.buttons["report-button"].tap()
        XCTAssertTrue(app.otherElements["survey-progress"].waitForExistence(timeout: 10)
                      || app.progressIndicators["survey-progress"].waitForExistence(timeout: 10))

        // Answer whatever the first page offers if it's a choice list; then
        // press NEXT until DONE appears, then DONE.
        let next = app.buttons["survey-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if app.buttons["Yes"].exists { app.buttons["Yes"].tap() }
        for _ in 0..<12 where next.label == "NEXT" {
            next.tap()
        }
        XCTAssertEqual(next.label, "DONE")
        next.tap()

        XCTAssertTrue(countLabel.waitForExistence(timeout: 10))
        XCTAssertNotEqual(countLabel.label, before)
    }
}
```

- [ ] **Step 3: Run the UI test**

Run: `xcodegen generate && xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | tail -5`
Expected: `TEST SUCCEEDED`. If element queries need adjusting to what SwiftUI actually exposes (e.g. the choice buttons render as `staticTexts`), fix the queries — the assertion contract (report count changes after DONE) must hold.

- [ ] **Step 4: Full DispatchKit suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit and push**

```bash
git add AppUITests project.yml
git commit -m "test: XCUITest smoke for the full report flow" && git push origin main
```

---

## Plan sequence reminder

- **This plan (2):** report flow + sensor capture ✅ testable via `swift test` + XCUITest
- Plan 3: home screen (themes, hexagon, AWAKE/ASLEEP), reports list/detail, question settings, custom tokens, onboarding
- Plan 4: prompting engine (timed distributions, interactive notifications + snooze, visit/Focus/wake/workout triggers, App Intents, Focus Filter extension with labels)
- Plan 5: visualizations + State of Mind write-through
- Plan 6: widgets + Control Center + weekly digest
- Plan 7: search + Spotlight, app lock, backfill
- Plan 8: iCloud sync config, auto-backup, export/import UI (incl. lenient per-record v1 decode), privacy manifest, accessibility pass, README, release
