# Dispatch Plan 43: change-since-last-report sensor windows

> **REQUIRED SUB-SKILL:** Use `superpowers:executing-plans` (or
> `superpowers:subagent-driven-development` when farming tasks out). Steps use
> checkbox (`- [ ]`) syntax so an agentic worker can execute task-by-task.

**Goal (issue #48):** For continuous HealthKit metrics, capture what happened
to the metric BETWEEN the previous report and this one — not just the
instantaneous value. The motivating case: file a report at a meeting's start
and end and see "Heart Rate: 72 → 88 bpm (+16) over 47 min". Heart rate ships
first; steps/flights already carry a since-last-report delta by construction
(their windowed `sum` landed in plan 2), so this plan adds the missing
interval summary (start, end, min, max) for heart rate, the honest degrade
rules around the window anchor, and the settings + report-detail surfaces.

## Architecture

The capture pipeline already threads a window anchor: `SurveyFlowView` passes
`DispatchStore.lastReportDate(in:)` into `SurveyController.providers(since:)`
(`App/Sources/Survey/SurveyController.swift`), and `HealthMetricProvider`
(`Shared/Providers/HealthProviders.swift`) uses `since ?? startOfDay` as the
query window. What's missing:

1. **`CaptureWindow`** (new, `Sources/DispatchKit/Capture/CaptureWindow.swift`)
   — a kit-pure value computing the statistics window from an anchor. The
   anchor is a PARAMETER (today: previous report date; future place/beacon
   triggers per #56/#60 pass "arrival time" instead — nothing here hardcodes
   "previous report"). Returns `nil` (degrade to absent) when there is no
   anchor or the anchor is not in the past; clamps oversized windows to a
   trailing cap.
2. **`SensorKind.healthHeartRange`** (new case) — a separate sensor so the
   windowed statistics are independently toggleable, independently
   timeout-raced, and can fail without touching the existing instantaneous
   Heart Rate sensor. Additive raw value; rides the existing `.health`
   permission (heartRate is ALREADY in `HealthKitReader.readTypes` — this
   plan adds NO new HealthKit read types and needs no purpose-string change).
3. **Reader window queries** — `HealthKitReader` gains
   `minMax(_:unit:from:to:)` (one `HKStatisticsQuery` with
   `[.discreteMin, .discreteMax]`) and `boundarySample(_:unit:from:to:newest:)`
   (limit-1 `HKSampleQuery` sorted by end date) so the provider can emit the
   window's first and last samples. Same `errorNoData → nil` semantics as the
   existing `average`.
4. **Readings, not composites** — the window summary is stored as additive
   `HealthReading` entries in the existing `Report.health` array:
   `heartRateStart`, `heartRateEnd`, `heartRateMin`, `heartRateMax` (unit
   `bpm`, `startDate` = window start, `endDate` = window end; the boundary
   readings carry their own sample dates). `HealthReading.type` is an open
   string, so storage, CloudKit sync, and V2 export/import are additive with
   zero schema or wire changes.
5. **`HeartRateWindowFormatter`** (new,
   `Sources/DispatchKit/Visualization/HeartRateWindowFormatter.swift`) — pure
   parsing of `[HealthReading]` into the report-detail line(s). Degrades
   per-piece: the delta line needs start+end; the range line needs min+max;
   either renders alone.
6. **UI surfaces** — Settings → Sensors HEALTH category gains a
   "Heart Rate Range" row (permission-fold pattern comes free via
   `SensorKind.permission → .health`); Report detail gains a heart-rate row
   fed by the formatter. The capture checklist is untouched (heart rate has
   never had a checklist row).

## Tech stack

Swift 6 / SwiftData (existing `Report.health` array), HealthKit
`HKStatisticsQuery` (`.discreteMin/.discreteMax`) + `HKSampleQuery`,
SwiftUI settings/detail rows, swift-testing in DispatchKit.

## Design decisions (decide + log)

- **Separate `SensorKind.healthHeartRange`, not folded into `.healthHeart`.**
  Chosen: independent toggle, independent timeout race, and a failed window
  query can never destroy the instantaneous reading (or vice versa).
  Rejected: extending `.healthHeart`'s payload — one slow statistics query
  would then time-out the whole heart capture, and users couldn't opt out of
  the window without losing the spot reading.
- **Raw `HealthReading` scalars, no `HeartRateWindow` Codable composite.**
  Chosen: four additive reading types in the existing array. Rejected: a new
  composite struct on `Report` — the SwiftData composite-storage SIGTRAP
  (renamed CodingKeys silently drop fields; bitten in plan 26 and plan 2)
  makes composites the risky path, and readings already carry window dates.
- **First report ever → absent, not zero.** `CaptureWindow.compute` returns
  nil without an anchor; the provider throws → the sensor records
  `.unavailable("no previous report…")` and the report simply has no window
  readings. Rejected: falling back to start-of-day (lies about what the
  window means) and emitting zeros (indistinguishable from a real reading).
- **Oversized windows clamp to a trailing 24 h, honestly labeled.** Chosen:
  `CaptureWindow` caps the window at 24 h before `now`; the readings'
  `startDate` reflects the CLAMPED start, so the detail line's "over N"
  duration is derived from stored dates and never overstates coverage.
  Rejected: refusing capture on big windows (loses data after a weekend away)
  and uncapped windows (a 5-day "since last report" min/max is meaningless
  and slow).
- **Anchor is a parameter.** `CaptureWindow.compute(anchor:now:cap:)` takes
  the anchor explicitly; `providers(since:)` passes the last report date.
  Future triggers (#56/#60 "heart rate for the 30 min after arriving") pass a
  different anchor with no changes to the window type. Rejected: reading the
  store inside the kit (kit stays framework-free and the anchor stays
  caller-defined).
- **The range sensor emits start/end even though `.healthHeart` has
  `heartRateLatest`.** Chosen: self-contained readings — the delta renders
  even when the instantaneous sensor is toggled off. The duplication is two
  doubles. Rejected: cross-sensor stitching in the formatter (coupling the
  two toggles).
- **No windowed avg reading.** `.healthHeart` already computes `heartRateAvg`
  over the same window (plan 2); duplicating it under a second type string
  invites drift. The detail row folds in `heartRateAvg` when present.
- **Charts/viz deferred.** Report detail is the only rendering surface in
  this plan. A viz treatment (windowed bands on the heart-rate chart) is
  follow-up work; filed as a checkbox in the completion notes, not here.
- **Steps/audio-level candidates deferred.** Steps' delta already exists
  (windowed sum). Audio level has no queryable history (point-in-time only
  per issue #48). No other sensor changes in this plan.

## Observable Acceptance Criteria

- Settings → Sensors shows a **Heart Rate Range** row under HEALTH with a
  toggle (`sensor-toggle-healthHeartRange`); the row uses the same
  permission fold as the other health rows (Request pill + disabled slider
  when Health authorization is not determined; free slider once
  granted/requested).
- Filing a report with mock sensors, the saved report's detail shows a
  **Heart rate** row reading `72 → 88 bpm (+16) · low 64 · high 112`
  (sensor row labeled "Heart rate", value from the formatter).
- A report captured with no previous report (first report ever) shows NO
  Heart rate window row in report detail — absent, not "0 → 0".
- Pre-existing reports (imported/older builds, no window readings) render
  report detail unchanged — no new row, no crash.
- The capture checklist is visually unchanged (no new row).

## Global constraints

- TDD kit-first: every kit type (`CaptureWindow`, formatter, SensorKind
  surfaces) gets a failing swift-testing test before implementation;
  `swift test` green at every commit.
- One commit per task; commits end
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- SwiftData raw-scalars rule: NO new Codable composite types with renamed
  CodingKeys; the plan stores plain `HealthReading`s only.
- Frozen accessibility identifiers: `sensor-toggle-healthHeartRange`
  (settings row); report-detail rows use the existing plain-tuple row
  rendering (no new identifier).
- Additive wire format: new reading types only; V2 export/import and CloudKit
  sync must round-trip them with no decoder changes.
- HealthKit access stays app-side behind `SensorProvider`; the kit never
  imports HealthKit. NO new entries in `HealthKitReader.readTypes` (heart
  rate is already authorized) and NEVER touch the medication types there
  (device-crash history, see the readTypes comment).
- Keep changes additive around plan-39's HealthKit surfaces (observers,
  AwakeStore, `SensorSettingsView` probe row) — new lines only, no
  refactoring of shared files.
- Full UI suite is the merge gate and runs outside this plan; local
  verification = `swift test` + `xcodegen` + build-for-testing.

---

### Task 1: CaptureWindow (kit)

**Files:**
- Create: `Sources/DispatchKit/Capture/CaptureWindow.swift`
- Test: `Tests/DispatchKitTests/CaptureWindowTests.swift`

**Interfaces:**
```swift
public struct CaptureWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let isClamped: Bool
    public static let defaultCap: TimeInterval  // 24 * 60 * 60
    public static func compute(anchor: Date?, now: Date,
                               cap: TimeInterval = defaultCap) -> CaptureWindow?
}
```

- [ ] Failing tests: nil anchor → nil; anchor == now → nil; anchor in the
      future → nil; normal anchor → `[anchor, now]`, `isClamped == false`;
      anchor older than cap → `[now - cap, now]`, `isClamped == true`;
      non-positive cap → nil (defensive).
- [ ] Implement; `swift test` green.
- [ ] Commit.

### Task 2: SensorKind.healthHeartRange (kit surfaces)

**Files:**
- Edit: `Sources/DispatchKit/Capture/SensorSettings.swift` (new case)
- Edit: `Sources/DispatchKit/Capture/SensorFailureHint.swift` (health hint +
  label "Heart Rate Range")
- Test: `Tests/DispatchKitTests/SensorSettingsTests.swift` (existing
  allCases loop covers the toggle), `Tests/DispatchKitTests/…FailureHint…`

**Interfaces:** `SensorKind.healthHeartRange` (raw `"healthHeartRange"`).

- [ ] Failing test: `SensorFailureHint.hint(for: .healthHeartRange, …)`
      returns the Health data-access hint;
      `disabledHint` names "Heart Rate Range".
- [ ] Add the case; fix every exhaustive switch the compiler flags in the
      kit; `swift test` green.
- [ ] Commit.

### Task 3: HeartRateWindowFormatter (kit)

**Files:**
- Create: `Sources/DispatchKit/Visualization/HeartRateWindowFormatter.swift`
- Test: `Tests/DispatchKitTests/HeartRateWindowFormatterTests.swift`

**Interfaces:**
```swift
public enum HeartRateWindowFormatter {
    /// Reading type constants: startType/endType/minType/maxType.
    public static func detailLine(from readings: [HealthReading]) -> String?
}
```

- [ ] Failing tests: full set → `"72 → 88 bpm (+16) · low 64 · high 112"`;
      negative delta renders `(-N)`; zero delta renders `(±0)`; min/max only
      → `"low 64 · high 112 bpm"`; start/end only → delta line without range;
      no window readings (or unrelated readings) → nil; values round to whole
      bpm.
- [ ] Implement as pure string shaping (no Foundation formatters that vary by
      locale for the arrow/delta; whole-number bpm).
- [ ] `swift test` green; commit.

### Task 4: Reader queries + provider case + wiring (app/shared)

**Files:**
- Edit: `Shared/Providers/HealthProviders.swift` (`minMax`,
  `boundarySample`, `case .healthHeartRange` in `HealthMetricProvider`)
- Edit: `App/Sources/Survey/SurveyController.swift` (provider list + mock:
  start 72 / end 88 / min 64 / max 112)
- Edit: `Watch/Sources/WatchProviders.swift` (provider list)
- Edit: `App/Sources/Privacy/SensorPermissions.swift`
  (`.healthHeartRange → .health`)

**Interfaces:** provider emits `HealthReading`s typed via
`HeartRateWindowFormatter.{start,end,min,max}Type`, `startDate` = window
start, `endDate` = window end (boundary readings keep their sample dates).

- [ ] `case .healthHeartRange`: `CaptureWindow.compute(anchor: since, now:
      now)`; nil window → `throw ProviderError("no previous report to
      measure from")`; run minMax + two boundary queries; all-nil results →
      the same honest unavailable; partial results emit what exists.
- [ ] Reader: `minMax` uses `errorNoData → nil` (matching `average`);
      boundary queries bound strictly to `[window.start, window.end]`.
- [ ] Mock provider added so `--mock-sensors` reports carry the readings.
- [ ] `swift test` green (kit untouched here, but run it), commit.

### Task 5: Settings row + report-detail row (app UI)

**Files:**
- Edit: `App/Sources/Settings/SensorSettingsView.swift` (HEALTH category
  array + `displayName` "Heart Rate Range"; update the "partition all 19
  cases" comment to 20)
- Edit: `App/Sources/Reports/ReportDetailView.swift` (heart-rate row via
  `HeartRateWindowFormatter.detailLine(from: report.health)`, icon
  `heart.fill`, label "Heart rate")

- [ ] Settings: row appears under HEALTH, alphabetically sorted, toggle id
      `sensor-toggle-healthHeartRange`, permission fold inherited.
- [ ] Detail: row renders only when the formatter returns a line; absent for
      old/first reports.
- [ ] Commit.

### Task 6: Verification + PR

- [ ] `swift test` (full kit suite) green.
- [ ] `xcodegen` then build-for-testing on iPhone 17 Pro simulator
      (wait for any running `xcodebuild test` to finish first).
- [ ] Push; PR "docs+feat: plan 43 — change-since-last-report sensor windows
      (issue #48)" with "Refs #48". Do NOT merge; full UI suite is the merge
      gate.
