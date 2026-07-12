# Dispatch Plan 44: Capture-time context metadata (CLLocation extras + device state + motion)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Issue:** #61 — *Sensors: speed, course, and heading capture.*

> **History:** v1 of this plan shipped speed/course/heading as three new
> user-visible SensorKinds (toggles, checklist rows, detail rows). Robbie's
> owner review on PR #72 redirected the design: "all of the CLLocation extras
> (really the entire CLLocation), including speed/course/heading should just
> be stored in payload metadata, rather than being a UI visible thing" —
> subsequently expanded to a general capture-time context-metadata feature
> (device state + motion family), then refined to give the metadata
> permission-grouped Sensors-screen toggles and report-DETAIL visibility
> (capture checklist stays untouched). This doc describes the final shape;
> the v1 SensorKinds were fully removed.

**Goal:** every report already takes a `CLLocation` fix for the location
sensor; most of that fix (speed, course, accuracies, floor, source flags) was
thrown away. Additionally, cheap capture-time context — device state and
motion classification — was never recorded. This plan stores all of it as
FLAT payload metadata: the CLLocation extras on `LocationSnapshot`, the
device/motion context as flat `Report` fields, with permission-grouped
Sensors-screen toggles, report-detail rows, and V2 export/import parity.

**Architecture:**
- `LocationSnapshot` gains flat optional fields (SwiftData trap: never store
  a Codable struct with custom/renamed CodingKeys as a `@Model` composite —
  flat fields only, no nested structs): `speedAccuracy`, `courseAccuracy`,
  `floorLevel` (CLFloor.level), `isSimulatedBySoftware`,
  `isProducedByAccessory` (CLLocationSourceInformation), `trueHeading`,
  `magneticHeading`, `headingAccuracy`; existing `speed`/`course`/
  `horizontalAccuracy`/`verticalAccuracy` are now pre-validated (CoreLocation
  `-1` sentinels degrade to nil via `MotionFormatting`).
- `Report` gains six flat optional metadata fields (additive-optional,
  lightweight-migration-safe): `isLowPowerMode`, `screenBrightness`,
  `interfaceStyle`, `audioOutputRoute` (Device Context) and
  `motionActivity`, `barometricPressureKPa` (Motion & Fitness).
- `CaptureMetadata` (kit): the transfer struct `ReportBuilder.save` accepts
  (`metadata:` parameter, defaulting to empty) and stamps onto the report.
- `CaptureMetadataFormatting` (kit, pure, TDD): brightness clamp, motion
  activity label collapse, audio route normalization, pressure validity.
- `MotionFormatting` (kit, pure, TDD): speed/course/heading/accuracy
  validity + mph and 16-point compass conversions.
- `ContextMetadataDetail` (kit, pure): shared App/Mac report-DETAIL row
  formatting (icon/label/value); nil fields render nothing.
- `CaptureMetadataReader` (App): assembles `CaptureMetadata` at capture time —
  main-actor device state reads (ProcessInfo/UIScreen/UITraitCollection/
  AVAudioSession) + `MotionActivityReader` (CMMotionActivityManager) +
  `BarometerReader` (CMAltimeter), all following PedometerReader's patterns
  (availability check → authorization check that NEVER prompts →
  `OneShotResumeGuard` against the CoreMotion completion double-fire trap).
- `HeadingReader` (Shared): one-shot CLHeading read folded into
  `LocationProvider.capture` — a separate magnetometer activation (the one
  extra capture cost this plan adds), bounded by an internal 2s timeout so a
  slow/absent compass never stalls the location capture.
- `V2Report` gains grouped DTO blocks `deviceState`/`motion` (pure-Codable
  composites are fine in the DTO layer; the SwiftData model stays flat);
  location extras ride the existing `location` object automatically.

**Tech Stack:** CoreLocation (CLLocation fields, CLHeading), CoreMotion
(CMMotionActivityManager, CMAltimeter), UIKit/AVFAudio (device state),
SwiftData additive-optional migration, Swift Testing.

## Design decisions (decide + log)

- **Metadata, not sensors.** No new capture SensorKinds, no
  CaptureCoordinator outcomes, no capture-checklist rows. The v1 approach
  (three SensorKinds) was rejected by owner review: this data is context
  riding existing capture, not independently interesting enough for
  per-field UI.
- **Permission-grouped toggles, not per-field rows.** Three Sensors-screen
  controls: the EXISTING Location toggle (caption expanded: "Includes
  altitude, speed, course, accuracy, floor, and compass heading."), a new
  **Motion & Fitness** toggle ("Activity type (walking, driving…) and
  barometric pressure.") 1:1 with the OS Motion & Fitness permission, and a
  new **Device Context** toggle ("Low Power Mode, screen brightness,
  appearance, audio output.") with NO OS permission. Implemented as two new
  `SensorKind` cases (`motionFitness`, `deviceContext`) — toggle-only kinds
  that reuse the existing settings storage, permission affordances, and
  `sensor-toggle-*` identifiers, but have no provider. Defaults ON (house
  style). Rejected separate UserDefaults keys: they'd duplicate the entire
  toggle/permission-affordance machinery.
- **Toggle-off ⇒ fields nil.** `CaptureMetadataReader` checks
  `settings.isEnabled(...)` per group; the location extras ride the location
  toggle inherently (they're read inside LocationProvider).
- **Never prompt at capture (the PedometerReader rule).** Motion reads gate
  on `CMMotionActivityManager/CMAltimeter.authorizationStatus() ==
  .authorized`; the Motion & Fitness dialog stays owned by PermissionCascade.
  Until granted, motion fields are nil. Device Context never has a dialog and
  must never render as "requestable" (`kind.permission == nil`, same as
  battery/connection — the request-all row keys on `SensorPermission` states,
  so it cannot regress).
- **Degrade-through, not zero.** CoreLocation's `-1` invalid sentinels
  (speed, course, all accuracies, heading degrees) become nil via
  `MotionFormatting` BEFORE storage. Same rule for non-finite brightness and
  non-positive pressure via `CaptureMetadataFormatting`.
- **Heading is CLHeading, not CLLocation.** It needs its own magnetometer
  activation (`startUpdatingHeading`, first sample, stop) — the one extra
  hardware cost of this plan. Folded into `LocationProvider.capture` (so it
  rides the location toggle and permission), single sample, 2s internal
  timeout, main-runloop delivery, continuation carries extracted Doubles
  (CLHeading isn't Sendable). `trueHeading` preferred at display, magnetic
  fallback.
- **Pressure comes from the RELATIVE altimeter only.**
  `CMAbsoluteAltitudeData` carries no pressure field, so
  `isAbsoluteAltitudeAvailable` doesn't help; only
  `isRelativeAltitudeAvailable` gates (documented at the reader).
- **Report DETAIL shows everything captured; capture checklist shows
  nothing.** Detail rows (App + Mac, shared `ContextMetadataDetail` kit
  formatting): location extras (Speed/Course/Heading/Floor/Accuracy/source
  flags) grouped right after the Altitude row; the context group (Activity,
  Pressure, Low Power Mode, Brightness, Appearance, Audio Output) trails the
  sensor section. Nil fields render no row. Source flags render only when
  true.
- **Exports:** V2 JSON round-trips everything (grouped `deviceState`/`motion`
  blocks, omitted when empty; location extras ride the `location` object).
  CSV/Markdown/DayOne are deliberately UNCHANGED — their fixed-column/front-
  matter formats stay lean; they only ever carried latitude/longitude/place
  location detail, and bloating them for metadata was rejected.
- **Watch: skipped.** No watch toggles, no watch metadata capture (fields nil
  on watch reports); the two new kinds are named in `watchDisplayName` for
  exhaustiveness only. The Mac app has no sensors settings screen (viewer
  only), so toggle parity doesn't apply; Mac report detail does render the
  synced fields.
- **Test environment:** metadata capture is skipped entirely under
  `--mock-sensors`/`--ui-testing` (deterministic runs never touch
  UIKit/CoreMotion state).

## Observable Acceptance Criteria

Observable via settings UI, report-detail UI, and exported data:

- Settings → Sensors shows the **Location** row with the caption "Includes
  altitude, speed, course, accuracy, floor, and compass heading."
  (`sensor-toggle-location` unchanged).
- Settings → Sensors DEVICE section shows a **Device Context** toggle
  (`sensor-toggle-deviceContext`) captioned "Low Power Mode, screen
  brightness, appearance, audio output." with NO Request/Settings affordance
  in any permission state, and a **Motion & Fitness** toggle
  (`sensor-toggle-motionFitness`) captioned "Activity type (walking,
  driving…) and barometric pressure." whose permission affordance follows the
  existing `motion` permission state exactly like the Stairs row.
- The "Request All Sensors…" row behavior is unchanged: it appears iff some
  `SensorPermission` is not-determined — verified by SensorSettingsUITests
  under `--mock-sensors` (the plan-43-scare regression check).
- The capture checklist (report entry) is UNCHANGED — no new rows.
- A report filed while moving with the toggles on shows, on its DETAIL
  screen (App and Mac): Speed ("12 mph"), Course/Heading ("180° S"), Floor,
  Accuracy ("±5 m") in the location group, and Activity/Pressure/Low Power
  Mode/Brightness/Appearance/Audio Output in the trailing context group;
  fields that weren't captured show no row. (Mac XCUITest note: SwiftUI Text
  content surfaces as the accessibility VALUE, not label, on macOS.)
- A V2 JSON export of such a report contains the location extras inside the
  `location` object and grouped `deviceState`/`motion` blocks; re-importing
  restores every field (round-trip kit test). Reports with no metadata omit
  both blocks.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement →
  green, per task.
- Flat fields only on SwiftData models; grouped composites allowed only in
  the pure-Codable V2 DTO layer.
- No capture path may ever trigger a permission dialog (PermissionCascade
  owns all dialogs).
- One scoped commit per task; `swift test` green before every commit. Do NOT
  touch signing/entitlements/branch-protection or the mac-ui-smoke workflow
  step. PR #72 stays open for review; do not merge.

---

### Task 1: Kit — validity/formatting helpers (TDD)

- [x] `MotionFormatting`: validSpeed/validCourse/validHeading/validAccuracy
  (negative → nil), mph conversion, 16-point compass. Tests pin the factor
  and the wraparound.
- [x] `CaptureMetadataFormatting`: normalizedBrightness (clamp 0...1,
  non-finite → nil), motionActivityLabel (priority automotive > cycling >
  running > walking > stationary; unknown fallback; none → nil),
  audioRouteLabel (strip trailing "Output"), validPressureKPa (positive
  finite only). Tests cover each rule.

### Task 2: Kit — storage + builder (TDD)

- [x] `LocationSnapshot` flat extras; `Report` six flat metadata fields;
  `CaptureMetadata` struct; `ReportBuilder.save(metadata:)` stamping (empty
  default keeps every existing call site working). Tests: metadata mapping,
  default-nil, location extras riding the payload.
- [x] `SensorKind.motionFitness`/`.deviceContext` toggle-only cases;
  SensorFailureHint exhaustiveness; toggle default-ON test.

### Task 3: Kit — V2 export/import parity (TDD)

- [x] `V2DeviceState`/`V2MotionState` grouped DTO blocks (omitted when
  empty), exporter/importer mapping. Round-trip test + empty-omission test;
  location extras verified riding the `location` object.

### Task 4: Capture — providers and readers

- [x] `LocationProvider.capture` populates the full CLLocation (validated)
  and folds in the one-shot `HeadingReader` (2s timeout, main-runloop
  delivery).
- [x] `CaptureMetadataReader` + `MotionActivityReader` + `BarometerReader`
  (App), PedometerReader patterns throughout; `SurveyController` runs the
  read alongside capture and passes the result to save (skipped in the test
  environment and for backdated reports).

### Task 5: Settings UI + detail UI

- [x] Sensors screen: caption support on rows; Location caption; Motion &
  Fitness (permission `.motion`) and Device Context (permission nil) toggles
  in the DEVICE category.
- [x] Report detail (App + Mac): shared `ContextMetadataDetail` rows —
  location extras after Altitude, context group trailing. Capture checklist
  untouched.
- [x] Watch: exhaustiveness-only display names; no toggles, no capture.

### Task 6: Verification + PR

- [x] Full `swift test`; DispatchApp + DispatchMac builds clean.
- [x] SensorSettingsUITests under `--mock-sensors` (requestable/hidden
  regression check for the new rows).
- [x] PR #72 updated (title/body + owner-rework note); stays open.

## Completion note (2026-07-11)

Reworked from the shipped v1 (three user-visible SensorKinds) to the final
metadata shape per owner review on PR #72 — see History above. `swift test`:
644 tests green (incl. Copilot-review wrap fix tests). DispatchApp
(App+Watch+widgets) and DispatchMac builds
clean. SensorSettingsUITests (--mock-sensors, iPhone 17 Pro simulator):
result recorded on the PR. Simulator screenshot review of the new detail
rows deferred to PR review.
