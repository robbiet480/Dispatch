# Dispatch Plan 28: Time question type

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a new question type — **time** — answering "What time did you last eat?"-style questions with a time-of-day wheel instead of free text: `QuestionType.time` end-to-end (model, capture, v2 export/import, CSV, editor, catalog, visualization), a survey `DatePicker(.hourAndMinute)` input with a one-tap "Now" button and a "Yesterday" chip, and an hour-of-day scatter visualization with an average-time stat.

**Architecture:** additive everywhere. `QuestionType` gains `time = 7` (next free raw; existing raws NEVER renumbered). The answer is a new kit value struct `TimeAnswer { minutesSinceMidnight, dayOffset }` riding a new `Response.timeResponse` payload variant (the `LocationAnswer` precedent), a new `AnswerValue.time` case through `ReportBuilder`, and a nil-omitted `V2Response.timeResponse` field. No per-question config in v1 (no min/max/step, no visualization-style override). Input UI is a new focused view file following the plan-21 `NumberInputViews.swift` patterns.

**Tech Stack:** SwiftData additive optional field (CloudKit-safe), Codable struct on the v2 wire, SwiftUI `DatePicker` (`.hourAndMinute`, wheel), Swift Charts `PointMark` scatter.

## Design decisions (decide + log)

- **Raw value:** `time = 7` — next free after `note = 6` (raws 0–6 verified against `Sources/DispatchKit/V1/V1Models.swift`). Frozen forever once shipped.
- **Answer semantics — WALL-CLOCK, timezone-independent:** a 9:00 breakfast stays 9:00 across timezones. Stored as `minutesSinceMidnight: Int` (0–1439), never a `Date`/epoch. **Why not the number path's `numericResponse: String`:** (a) three consumers blind-parse `Double(numericResponse)` by prompt/identifier match — `VisualizationData.buildNumericSeries`, `InsightsEngine.swift:376`, `DigestStats.swift:127` — and would misread minutes as plain numbers if a question's type ever changed or joins went by prompt; (b) `CSVExporter.flatten` would print raw minute ints; (c) there is no slot for `dayOffset`. A dedicated Codable struct payload variant matches how `location` answers already work (`Response.locationResponse: LocationAnswer?`) and preserves `flatten`'s documented one-populated-variant-per-response contract.
- **`dayOffset` — "answered at 00:30, meant yesterday evening":** `Int`, `0` = today, `-1` = yesterday; toggled by a "Yesterday" chip in the input UI. **v1 UI writes only these two values**; storage/import tolerate any int (the raw-leniency precedent — unknown values import, persist, and re-export untouched). On the wire `dayOffset` is OMITTED when 0 (nil-omission convention), tolerated when absent.
- **Leniency:** importer stores `minutesSinceMidnight` as-is (even out-of-range); display sites read `clampedMinutes` (0...1439). Unknown `questionType` raws keep today's behavior — `Question.type` falls back to `.tokens` (`RawValueFallbackTests` pins it with 99); an old app build seeing a synced time question renders it as tokens, same norm as every prior additive raw.
- **CSV:** the exporter's invariant today is fixed sensor columns + ONE column per question prompt, single flattened string each. Time questions export **"HH:mm"** (zero-padded 24-hour, locale-independent) in the prompt column, **plus a companion column `"<prompt> (day offset)"` appended immediately after that prompt's column, emitted for every time-typed question** (header always present, value `0`/`-1`, empty when unanswered). Decided over baking the offset into the time string: keeps "HH:mm" machine-parseable and the offset numeric; the header is deterministic (not data-dependent), and existing consumers' column-by-prompt lookups keep working because only time questions (new) grow a companion. NOTE: plan 26's branch appends a `connection` sensor column — rebase-aware: append after whatever `sensorColumns` tail exists at implementation time.
- **Average-time stat uses the circular (vector) mean, not arithmetic:** times cluster around midnight (23:30 and 00:30 must average to midnight, not noon). Map minutes to angles, average the unit vectors, `atan2` back; when the resultant vector is ~zero (e.g. two answers exactly 12 h apart) fall back to the arithmetic mean for determinism. `dayOffset` shifts the point's plotted DATE (x-axis), never the time-of-day (y-axis).
- **Catalog: time questions ARE allowed in community submissions.** `CatalogValidation.validate` resolves through `QuestionType(rawValue:)`, so adding the enum case makes raw 7 structurally valid automatically — the decision is to KEEP that (no exclusion list). Choices stay forbidden for time (the existing non-multipleChoice `choicesNotAllowed` branch already covers it — pin with a test). `dispatch-mod` renders the type via `String(describing:)` (`Dashboard.swift:121`, `DispatchMod.swift:65,194`) so "time" appears with zero changes; older app builds show catalog time entries as "Unknown type" (`CatalogView.swift:123` already guards) — documented in `docs/moderation.md`.
- **No visualization-style override in v1:** `VisualizationStyle.isCompatible(with:)` matches no style for `.time`, so the editor's VISUALIZATION picker section stays hidden (same as location/note) and `VisualizationData.build` always dispatches to the new time aggregation by type.
- **Quick answers, insights, digest, search: untouched in v1.** `QuickAnswerFiler` is yesNo-only by contract; `InsightsEngine`/`DigestStats` numeric branches key off `numericResponse` and simply never see time answers; time answers aren't text-searchable. All explicitly out of scope.
- **Watch is a CONDITIONAL task** — PR #26 (`plan-19-watch-app`) is in flight. If it has merged by execution time, add a crown-scrollable minimal time input; if not, SKIP Task 5 and record the integration point in the completion note (the exhaustive `switch question.type` in `Watch/Sources/WatchQuestionView.swift` will force the decision at that branch's next rebase anyway).

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate).
- Additive v2 format only: `timeResponse` optional and omitted when nil; `dayOffset` omitted when 0; import tolerates absence and unknown values (raw-leniency norm); NO schemaVersion bump; NEVER renumber existing `QuestionType` raws 0–6.
- No new entitlements, no new permissions, no Info.plist changes.
- Adding a `QuestionType` case breaks every non-defaulted `switch` on it — that compile-error list IS the integration checklist (`QuestionPageView.answerBody`, `VisualizationData.build`, `QuestionType.displayName` in `QuestionSettingsView.swift`, plus whatever else the compiler finds). Fix each deliberately; never add a `default:`.
- Accessibility bar (plan 17): the chip/button controls carry identifiers + labels; the system `DatePicker` inherits native accessibility; Dynamic Type survives XXL.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.

---

### Task 1: Kit — TimeAnswer value, QuestionType.time, answer plumbing, v2 round-trip

**Files:**
- Modify: `Sources/DispatchKit/V1/V1Models.swift` (QuestionType), `Sources/DispatchKit/Models/Values.swift` (TimeAnswer), `Sources/DispatchKit/Models/Response.swift`, `Sources/DispatchKit/Capture/ReportBuilder.swift` (AnswerValue + save switch), `Sources/DispatchKit/V2/V2Models.swift`, `Sources/DispatchKit/V2/V2Exporter.swift`, `Sources/DispatchKit/Import/V2Importer.swift`
- Test: create `Tests/DispatchKitTests/TimeAnswerTests.swift`; extend `RawValueFallbackTests.swift`, `ReportBuilderTests.swift`, `RoundTripTests.swift`, `V2ExportTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `QuestionType.time` (raw 7)
- `TimeAnswer { minutesSinceMidnight: Int, dayOffset: Int }` + `clampedMinutes`, `hhmm`, `displayText(locale:)`, `TimeAnswer.now(_:calendar:)`
- `AnswerValue.time(TimeAnswer)`, `Response.timeResponse: TimeAnswer?`, `V2Response.timeResponse: TimeAnswer?`

- [ ] **Step 1: Write the failing tests.** `TimeAnswerTests.swift`: (a) raw-value freeze — `#expect(QuestionType.time.rawValue == 7)` plus the existing seven raws literally, so renumbering breaks loudly; (b) wire shape — encoding `TimeAnswer(minutesSinceMidnight: 540)` produces `minutes` key and NO `dayOffset` key; encoding with `dayOffset: -1` includes it; decoding `{"minutes": 540}` yields `dayOffset == 0`; decoding `{"minutes": 90, "dayOffset": -3}` preserves `-3` through re-encode (leniency); (c) `clampedMinutes` — `-10 → 0`, `2000 → 1439`, `540 → 540`; (d) `hhmm` — `540 → "09:00"`, `0 → "00:00"`, `1439 → "23:59"`, out-of-range `2000 → "23:59"` (clamped); (e) `displayText` — with a fixed `Locale(identifier: "en_US")`: `540/0 → "9:00 AM"`, `1350/-1 → "10:30 PM (yesterday)"`; (f) `TimeAnswer.now` — with a fixed calendar/date, returns that wall-clock minute and `dayOffset == 0`. Extend `RawValueFallbackTests`: `typeRaw = 7 → .time`; `typeRaw = 99 → .tokens` (existing assertion untouched). Extend `ReportBuilderTests`: an `AnswerDraft` with `.time(TimeAnswer(minutesSinceMidnight: 555, dayOffset: -1))` lands on `response.timeResponse`; a skipped time question stays payload-less. Extend `RoundTripTests`/`V2ExportTests`: a report with a time response round-trips both fields; nil `timeResponse` is OMITTED from encoded JSON (extend the existing nil-omission test); a pre-plan-28 v2 payload (no `timeResponse` key) imports with nil (absence tolerance).
- [ ] **Step 2: Run `swift test` — expect FAIL** (case and types don't exist).
- [ ] **Step 3: Implement.** `V1Models.swift`: append `case time = 7` with a `/// 7+ are additive (plan 28) — NEVER renumber` comment. `Values.swift` (near `LocationAnswer`):

```swift
/// Wall-clock time-of-day answer (plan 28). Timezone-independent by
/// construction: minutes since local midnight, never a Date — a 9:00
/// breakfast stays 9:00 across timezones. `dayOffset` handles the
/// "answered at 00:30, meant yesterday evening" case: 0 = today,
/// -1 = yesterday (the only values the v1 UI writes; storage tolerates
/// other ints per the raw-leniency precedent).
public struct TimeAnswer: Codable, Hashable, Sendable {
    /// Nominal range 0...1439. Imported values are stored as-is
    /// (leniency); display sites read `clampedMinutes`.
    public var minutesSinceMidnight: Int
    public var dayOffset: Int

    enum CodingKeys: String, CodingKey {
        case minutesSinceMidnight = "minutes"
        case dayOffset
    }

    public init(minutesSinceMidnight: Int, dayOffset: Int = 0) {
        self.minutesSinceMidnight = minutesSinceMidnight
        self.dayOffset = dayOffset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minutesSinceMidnight = try container.decode(Int.self, forKey: .minutesSinceMidnight)
        dayOffset = try container.decodeIfPresent(Int.self, forKey: .dayOffset) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minutesSinceMidnight, forKey: .minutesSinceMidnight)
        if dayOffset != 0 { try container.encode(dayOffset, forKey: .dayOffset) }
    }

    public var clampedMinutes: Int { min(max(minutesSinceMidnight, 0), 1439) }

    /// Locale-independent "HH:mm" (24-hour, zero-padded) — the CSV/wire
    /// display form.
    public var hhmm: String {
        String(format: "%02d:%02d", clampedMinutes / 60, clampedMinutes % 60)
    }

    /// Locale-aware display, e.g. "9:00 AM" / "10:30 PM (yesterday)".
    public func displayText(locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let date = calendar.date(bySettingHour: clampedMinutes / 60,
                                 minute: clampedMinutes % 60, second: 0,
                                 of: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        return dayOffset == -1 ? "\(time) (yesterday)" : time
    }

    /// The current wall-clock minute — the survey's "Now" button value.
    public static func now(_ date: Date = Date(), calendar: Calendar = .current) -> TimeAnswer {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return TimeAnswer(minutesSinceMidnight: (components.hour ?? 0) * 60 + (components.minute ?? 0))
    }
}
```

Wiring (each additive): `Response` gains `public var timeResponse: TimeAnswer?` (optional Codable struct — the `locationResponse` precedent, CloudKit-safe); `AnswerValue` gains `case time(TimeAnswer)`; `ReportBuilder.save`'s answer switch gains `case .time(let answer): response.timeResponse = answer` (no `normalizeEmpty` change — a time value is never "empty"); `V2Response` gains `public var timeResponse: TimeAnswer?` with the standard "omitted when nil; import tolerates absence" doc comment; `V2Exporter.reportDTO` gains `rdto.timeResponse = resp.timeResponse`; `V2Importer` gains `response.timeResponse = rdto.timeResponse`.
- [ ] **Step 4: Run `swift test` — expect PASS** (whole kit suite; the app target is NOT expected to build until Task 4 fixes its exhaustive switches — kit-only commit, same convention as plan 26 Tasks 3/4).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): time question type — TimeAnswer, answer plumbing, v2 round-trip"` → push.

### Task 2: Kit — CSV export + catalog validation + moderation docs

**Files:**
- Modify: `Sources/DispatchKit/Export/CSVExporter.swift`, `docs/moderation.md`
- Test: extend `Tests/DispatchKitTests/CSVExportTests.swift`, `Tests/DispatchKitTests/CatalogTests.swift`

- [ ] **Step 1: Write the failing tests.** `CSVExportTests`: a time question titled "What time did you last eat?" produces headers `..., "What time did you last eat?", "What time did you last eat? (day offset)"` (companion immediately after the prompt column, non-time questions unchanged); an answered report renders `"09:15"` and `"0"`; a yesterday answer renders `"23:30"` and `"-1"`; an unanswered report renders empty in BOTH columns; a mixed-question export keeps non-time columns byte-identical to before. `CatalogTests`: `CatalogValidation.validate(prompt: "What time did you last eat?", typeRaw: QuestionType.time.rawValue, choices: [])` returns no errors (the allow decision, pinned); same call with `choices: ["Morning"]` returns `[.choicesNotAllowed]`; `typeRaw: 99` still returns `[.unknownQuestionType(raw: 99)]`.
- [ ] **Step 2: Run `swift test` — expect FAIL** (CSV columns missing; catalog time-allowed test fails only if Task 1 unmerged — it should already pass, keep it as a pin).
- [ ] **Step 3: Implement CSV.** In `exportCSV`, replace the prompt-column derivation so time questions grow the companion header, and thread question types into the row loop:

```swift
// One column per prompt, plus a "(day offset)" companion immediately
// after every TIME question's column (plan 28): keeps the time value
// cleanly machine-parseable ("HH:mm") and the offset numeric, without
// disturbing column-by-prompt lookups for existing question types.
var questionColumns: [String] = []
for question in questions {
    questionColumns.append(question.prompt)
    if question.type == .time { questionColumns.append("\(question.prompt) (day offset)") }
}
```

and in the per-report loop:

```swift
for question in questions {
    let response = byPrompt[question.prompt]
    fields.append(flatten(response))
    if question.type == .time {
        fields.append(response?.timeResponse.map { String($0.dayOffset) } ?? "")
    }
}
```

`flatten` gains, in the positional precedence chain (before the final `textResponses` check, matching the one-variant contract comment): `if let time = response.timeResponse { return time.hhmm }`.
- [ ] **Step 4: Docs.** `docs/moderation.md`: note in the catalog schema/moderation section that time questions (typeRaw 7) are accepted in community submissions as of plan 28, carry no choices, and that app builds older than plan 28 show such catalog entries as "Unknown type" and cannot install them (forward-lenient, no moderator action needed).
- [ ] **Step 5: Run `swift test` — expect PASS.** Commit — `git commit -m "feat(kit): time answers in CSV export + catalog validation pin"` → push.

### Task 3: Kit — hour-of-day visualization aggregation

**Files:**
- Modify: `Sources/DispatchKit/Visualization/VisualizationData.swift` (new case + builder + `==`)
- Test: extend `Tests/DispatchKitTests/VisualizationDataTests.swift`

**Interfaces (produced — Task 4 relies on these exact names):**
- `QuestionVisualization.timePoints(points: [(date: Date, minutes: Int)], averageMinutes: Int)`

- [ ] **Step 1: Write the failing tests.** (a) A time question over three reports yields `.timePoints` with chronologically sorted points carrying each answer's `clampedMinutes`; (b) a `dayOffset: -1` answer plots at `report.date - 86_400` (date shifted, minutes unshifted); (c) circular average: answers at 23:30 and 00:30 average to 0 (midnight), NOT 720; answers at 08:00/09:00/10:00 average to 540; (d) degenerate opposite pair (06:00 and 18:00 — zero resultant vector) falls back to the arithmetic mean (720) deterministically; (e) no answered responses → `.empty`; (f) skipped/other-variant responses ignored.
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement.** Add the enum case with doc comment `/// Time questions (plan 28): each report a point at its answered wall-clock minute; average is the CIRCULAR mean (23:30 + 00:30 → midnight).`, extend the custom `==` (points count + elementwise date/minutes + averageMinutes equality), route `case .time:` in `build`'s type switch to a new builder:

```swift
private static func buildTimePoints(responses: [Response], reports: [Report]) -> QuestionVisualization {
    let responseToReport = Dictionary(uniqueKeysWithValues: reports.flatMap { report in
        (report.responses ?? []).map { (ObjectIdentifier($0), report) }
    })
    var points: [(date: Date, minutes: Int)] = []
    for response in responses {
        guard let time = response.timeResponse,
              let report = responseToReport[ObjectIdentifier(response)] else { continue }
        // dayOffset shifts the plotted DATE; the wall-clock minute is sacred.
        let date = report.date.addingTimeInterval(TimeInterval(time.dayOffset) * 86_400)
        points.append((date: date, minutes: time.clampedMinutes))
    }
    guard !points.isEmpty else { return .empty }
    points.sort { $0.date < $1.date }
    return .timePoints(points: points, averageMinutes: circularMeanMinutes(points.map(\.minutes)))
}

/// Circular (vector) mean of minutes-of-day: times clustering around
/// midnight average correctly (23:30 & 00:30 → 00:00). A near-zero
/// resultant vector (perfectly opposed times) has no meaningful circular
/// mean — fall back to the arithmetic mean for determinism.
private static func circularMeanMinutes(_ minutes: [Int]) -> Int {
    let angles = minutes.map { Double($0) / 1440 * 2 * .pi }
    let x = angles.reduce(0) { $0 + cos($1) } / Double(angles.count)
    let y = angles.reduce(0) { $0 + sin($1) } / Double(angles.count)
    guard x * x + y * y > 1e-9 else {
        return minutes.reduce(0, +) / minutes.count
    }
    var angle = atan2(y, x)
    if angle < 0 { angle += 2 * .pi }
    return Int((angle / (2 * .pi) * 1440).rounded()) % 1440
}
```

(`matchingResponses` and the style-override gate are untouched — `.time` has no compatible `VisualizationStyle`, so the override branch can never fire for it.)
- [ ] **Step 4: Run `swift test` — expect PASS.** Commit — `git commit -m "feat(kit): hour-of-day visualization — time points + circular average"` → push.

### Task 4: App — survey time input, editor fallout, report detail, viz page

**Files:**
- Create: `App/Sources/Survey/TimeInputView.swift`
- Modify: `App/Sources/Survey/QuestionPageView.swift` (`.time` case), `App/Sources/Settings/QuestionSettingsView.swift` (`QuestionType.displayName`), `App/Sources/Reports/ReportDetailView.swift` (`answerText`), `App/Sources/Visualizations/QuestionVisualizationView.swift` (`.timePoints` case + `TimePointsView`), plus every remaining non-defaulted `switch` the compiler flags
- Test: extend the UI suite (survey renders the wheel; Now + Yesterday file the expected answer; report detail shows it)

**Interfaces (consumed):** Task 1's `AnswerValue.time`/`TimeAnswer`, Task 3's `.timePoints`.

- [ ] **Step 1: TimeInputView.** New file, following the `NumberInputViews.swift` conventions (header doc comment stating the write path and flush-registry stance, focused structs, identifiers):

```swift
import DispatchKit
import SwiftUI

/// Time-question input (plan 28). Wheel `DatePicker(.hourAndMinute)`
/// seeded to the current time, a prominent "Now" button that one-taps
/// the current wall-clock minute, and a "Yesterday" chip toggling
/// `dayOffset` between 0 and -1. Untouched = skipped (the number-control
/// convention): the wheel display dims until the first interaction, and
/// only interactions write `.time` through `onAnswer`. No keyboard, so
/// nothing registers with the survey's flush registry.
struct TimeInput: View {
    let value: TimeAnswer? // nil = untouched
    let onAnswer: (TimeAnswer) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(current.displayText())
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .opacity(value == nil ? 0.4 : 1) // dimmed until touched
                .accessibilityHidden(true) // the picker announces the value
            DatePicker("Time", selection: wheelBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .accessibilityIdentifier("time-picker")
            HStack(spacing: 12) {
                Button("Now") { onAnswer(TimeAnswer.now()) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("time-now")
                YesterdayChip(isOn: current.dayOffset == -1) {
                    // Toggling commits the currently displayed wheel time.
                    onAnswer(TimeAnswer(minutesSinceMidnight: current.minutesSinceMidnight,
                                        dayOffset: current.dayOffset == -1 ? 0 : -1))
                }
            }
        }
        .padding()
    }

    private var current: TimeAnswer { value ?? .now() }

    /// Wheel Date ⇄ TimeAnswer bridge: only the hour/minute components
    /// matter; any wheel movement commits (preserving the chip's offset).
    private var wheelBinding: Binding<Date> { /* dateComponents round-trip */ }
}
```

`YesterdayChip`: a small capsule toggle button (selected state filled), `.accessibilityIdentifier("time-yesterday")`, `.accessibilityLabel("Yesterday")`, `.accessibilityAddTraits(isOn ? .isSelected : [])`. All labels use scalable text styles (Dynamic Type XXL per the plan-17 bar).
- [ ] **Step 2: Wire the survey.** `QuestionPageView.answerBody` gains `case .time:` rendering `TimeInput(value: currentTime, onAnswer: { onAnswer(.time($0)) })` where `currentTime` is `if case .time(let t) = value { t } else { nil }`. No flush-registry registration (no keyboard — the plan-21 non-text-style precedent).
- [ ] **Step 3: Fix every exhaustive-switch compile error deliberately** (never `default:`): `QuestionType.displayName` gains `case .time: "Time"` (the editor's and catalog submit form's `allCases` pickers then show Time automatically — no picker code changes); `ReportDetailView.answerText` gains, in the precedence chain, `if let time = response.timeResponse { return time.displayText() }`; the editor's number-only sections (input style, default answer) must NOT appear for `.time` (they're already type-gated — verify); sweep the remainder the compiler flags and record any surprises in the completion note.
- [ ] **Step 4: Viz page.** `QuestionVisualizationView` gains `case .timePoints(let points, let averageMinutes): TimePointsView(...)`. `TimePointsView` mirrors `NumericSeriesView`'s structure: Swift Charts `PointMark(x: .value("Date", date), y: .value("Minutes", minutes))` scatter (each report a dot at its answered time), `RuleMark` at `averageMinutes`, y-axis domain `0...1440` with labeled gridlines at 0/360/720/1080/1440 rendered as locale short times ("12 AM", "6 AM", …), stat footer `"AVERAGE " + TimeAnswer(minutesSinceMidnight: averageMinutes).displayText()`, and an `accessibilityLabel` summary (count, earliest, latest, average) like `NumericSeriesView`'s.
- [ ] **Step 5: UI test.** Create a time question via the editor (type picker → Time), run a survey (`--mock-sensors`), tap Now, tap the Yesterday chip, DONE; assert the report detail row shows a time string containing "(yesterday)". A second flow leaves the wheel untouched and asserts the question records no answer.
- [ ] **Step 6: Verify** — `swift test`, `xcodebuild build-for-testing`, UI suite. Commit — `git commit -m "feat: time question — survey wheel input, editor, detail, hour-of-day scatter"` → push.

### Task 5 (CONDITIONAL — only if PR #26 `plan-19-watch-app` has merged): Watch minimal time input

**Files:**
- Modify: `Watch/Sources/WatchQuestionView.swift` (the exhaustive `switch question.type` at ~line 65 and the answer-mapping switch at ~line 131), possibly `Watch/Sources/WatchFilingController.swift` (only if answer plumbing needs the new case surfaced)

- [ ] **Step 1: Gate check.** `git log main --oneline | grep -i watch` / `gh pr view 26` — if PR #26 is NOT merged, skip this task entirely and add a completion-note line naming the two switches above as the integration points.
- [ ] **Step 2: Minimal input.** `WatchQuestionView`'s type switch gains `case .time:` — a crown-scrollable picker: `Text(display)` + `.focusable().digitalCrownRotation(...)` over 0–1439 in 5-minute detents (or a native `Picker` of 5-minute steps if crown plumbing fights the layout — decide on-device, record the choice), seeded to `TimeAnswer.now()`, plus a compact "Yesterday" toggle. Confirm files `.time(TimeAnswer(...))` through the existing `AnswerValue` path — `Response.timeResponse` and v2 sync shipped in Task 1, so the phone reconciles watch-filed time answers with zero further kit work. No new watch settings.
- [ ] **Step 3: Verify** — watch scheme builds; file a time answer in the watch simulator and confirm the phone report detail renders it. Commit — `git commit -m "feat(watch): minimal crown-scrollable time input"` → push.

### Task 6: Wrap + self-review

- [ ] Full suites green (`swift test`, app build-for-testing, UI suite at the merge gate); note test-count delta from the previous plan's final report.
- [ ] Self-review the whole branch diff before handing to review: (a) no `default:` added to any QuestionType/AnswerValue switch; (b) `timeResponse` nil-omission + `dayOffset`-0 omission proven by tests; (c) CSV non-time columns byte-identical (test pins it); (d) no `Date`/epoch stored anywhere for the answer value; (e) grep `numericResponse` consumers (`InsightsEngine`, `DigestStats`, `VisualizationData`) to confirm none accidentally ingest time answers; (f) accessibility identifiers `time-picker`, `time-now`, `time-yesterday` present.
- [ ] Completion note in this doc (what shipped, divergences, test counts, the Task 5 outcome). Whole-branch review follows (controller-driven).

---

## Completion note (2026-07-10, branch `plan-28-time-question`)

**Shipped, task by task:**
- **Task 1 (kit):** `QuestionType.time = 7`; `TimeAnswer { minutesSinceMidnight, dayOffset }` with `clampedMinutes`/`hhmm`/`displayText(locale:)`/`now(_:calendar:)`; `Response.timeResponse`, `AnswerValue.time`, `V2Response.timeResponse`; exporter/importer wiring. All exactly per the plan's code blocks.
- **Task 2 (kit):** CSV companion `(day offset)` column per time question; `flatten` emits `hhmm`; `docs/moderation.md` notes time questions accepted in submissions (forward-lenient for old builds). Catalog needed NO source change — raw 7 resolves structurally through `QuestionType(rawValue:)`; pinned with a dedicated test.
- **Task 3 (kit):** `QuestionVisualization.timePoints`, `buildTimePoints`, `circularMeanMinutes` (with arithmetic fallback for zero-resultant pairs), `==` extension.
- **Task 4 (app):** `TimeInputView.swift` (`TimeInput` + `YesterdayChip`); `.time` case in `QuestionPageView.answerBody`; `QuestionType.displayName` → "Time"; `ReportDetailView.answerText`; `TimePointsView` PointMark scatter with 0…1440 y-domain and circular-average rule; **plus `SurveyFlowView.keyboardPageID`** (an exhaustive switch the compiler flagged beyond the plan's named list — returns nil, no keyboard). Two UI tests added (Now+Yesterday saves; untouched records nothing).
- **Task 5 (watch): DONE — PR #26 (watch app) is merged on main.** Added a crown-scrollable `timeControls` (digital-crown over 0…1439 in 5-min detents, seeded to now) + a Yesterday `Toggle` + File, in the `switch question.type` at `WatchQuestionView.inputControls`. Files `.time` through the existing `WatchReportFiler`/`ReportBuilder` path — zero extra kit work. a11y ids `watch-time-readout`/`watch-time-yesterday`/`watch-file-time`.

**Divergences from the plan:**
- Task 1's Step 4 requires the kit suite green, but adding `QuestionType.time` breaks `VisualizationData.build`'s exhaustive switch (the real aggregation is Task 3). Resolved by landing an explicit `case .time: return .empty` placeholder in Task 1 (NOT a `default:`), replaced with `buildTimePoints` in Task 3. No behavior change between commits — the app target doesn't build until Task 4 anyway.
- `SurveyFlowView.keyboardPageID` was an extra exhaustive switch beyond the plan's enumerated sites; handled with an explicit `case .time: return nil`.
- `displayText` tests normalize U+202F/U+00A0 (newer OSes put a narrow no-break space before AM/PM) so the assertions track meaning, not the platform's space glyph.

**Verification:** kit `swift test` green (XCTest suite passes; swift-testing side records 0 issues — the signal-5 runner-exit crash is the documented flake). App `xcodebuild build-for-testing` (iPhone 17 Pro sim, DispatchApp scheme, which also builds Watch + Widgets + UITests): **TEST BUILD SUCCEEDED**. Full UI suite deliberately NOT run — reserved for the merge gate. New tests: ~22 kit (TimeAnswer 10, RawValueFallback +1, ReportBuilder +1, V2Export +2, CSVExport +1, Catalog +1, VisualizationData +6) + 2 UI.
