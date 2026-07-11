# Dispatch Plan 44: Speed, course, and heading sensors

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Issue:** #61 — *Sensors: speed, course, and heading capture.*

**Goal:** every report already takes a `CLLocation` fix for the location sensor; `speed`/`course` are fields ON that same fix that are currently read into `LocationSnapshot` but never surfaced as their own toggleable sensors, mirroring how `altitude` already rides the shared fix. Heading is one extra magnetometer read (`CLLocationManager.startUpdatingHeading`), iPhone-only. This plan adds three new `SensorKind`s — `.speed`, `.course`, `.heading` — following the exact `AltitudeFromLocationProvider` pattern, with per-row toggles, capture-checklist rows, report-detail display, and export parity.

**Architecture:**
- `SensorPayload` gains `.speed(Double)` (m/s), `.course(Double)` (degrees), `.heading(Double)` (degrees) — raw values, formatted at display time.
- `Report` gains `speedMPS: Double?`, `courseDegrees: Double?`, `headingDegrees: Double?`, mirroring `altitudeMeters`.
- New pure formatter `Sources/DispatchKit/Capture/MotionFormatting.swift`: degrades CoreLocation's invalid-reading sentinel (`speed`/`course` are `-1` when the fix can't support them) to `nil` rather than surfacing a nonsensical negative value, plus m/s→mph conversion and a 16-point compass-label helper — all pure and kit-testable.
- New providers in `Shared/Providers/LocationProvider.swift`: `SpeedFromLocationProvider` and `CourseFromLocationProvider` (mirror `AltitudeFromLocationProvider` — await the session's shared `LocationFixStore` fix, degrade an invalid reading to `.unavailable`). New `HeadingProvider` (own `CLLocationManager`, `startUpdatingHeading`/delegate, single sample then stop; `.unavailable` when `CLLocationManager.headingAvailable()` is false — iPad/Watch/Mac).
- Both platforms' provider lists, mocks, settings categories, capture checklists, and report-detail rows get the three new rows, following `altitude`'s existing wiring line-for-line. Heading is phone-only (own `CLLocationManager`, not tied to the shared location fix) — absent from the watch's `watchCapableKinds` and provider list, matching the design note.
- Exporters (CSV, Markdown, DayOne, V2 JSON) gain columns/fields for the three new values, following `altitudeMeters`'s existing per-exporter wiring.

**Tech Stack:** CoreLocation (`CLLocation.speed`/`.course`, `CLLocationManager.startUpdatingHeading`/`CLHeadingManager` delegate), existing `LocationFixStore` actor, SwiftData (`Report` additive optional columns — lightweight-migration-safe), Swift Testing (`swift test`).

## Design decisions (decide + log)

- **Store raw units, format at display time.** `Report.speedMPS`/`courseDegrees`/`headingDegrees` store SI units (m/s, degrees) — same rule as every other sensor (`altitudeMeters` stores meters even though the UI shows feet). Display converts to mph; rejected storing pre-converted mph (would bake in a unit choice and break re-formatting later, same reasoning as altitude/weather's existing raw-storage convention).
- **Degrade-through, not zero, for invalid readings.** CoreLocation returns `-1` for `speed`/`course`/`speedAccuracy`/`courseAccuracy` when the fix can't support them (stationary, poor accuracy, no course estimate) — `MotionFormatting.validSpeed`/`validCourse` map negative raw values to `nil`, and the two providers resolve `.unavailable` in that case rather than capturing a misleading `0`. This is the same "degrade through absence" pattern used for `MediaSample` in plan 26.
- **Heading is its own provider, not location-fix-derived.** Unlike speed/course (fields on the same `CLLocation` fix), heading comes from a distinct magnetometer read via a *second* `CLLocationManager.startUpdatingHeading()` call — rejected reusing `LocationFixStore` (wrong data source, and heading availability is device-class-gated independently of location). `HeadingProvider` owns its own manager instance, checks `CLLocationManager.headingAvailable()` up front, takes the first delegate callback, and stops immediately (single-sample, same shape as `LocationProvider.requestFix`).
- **Heading is phone-only; speed/course are cross-platform.** The issue's own design note says the watch's `CLLocation` carries the same speed/course fields ("should work on both capture platforms"), so `SpeedFromLocationProvider`/`CourseFromLocationProvider` are added to `WatchProviders.watchCapableKinds`. Heading has no such note and `CLLocationManager.headingAvailable()` is false on watchOS/iPadOS/macOS in practice — `HeadingProvider` is iPhone-app-only, mirroring how `photos`/`audio`/`connection`/`focus` are already phone-only and simply absent from the watch's kind list.
- **All three land in the existing LOCATION & WEATHER settings category** alongside `location`/`weather`/`altitude` — they all ride the same location permission and conceptually belong with the location-derived group (matches the issue's suggested bucket).
- **Permission: `.location`, same as `altitude`/`weather`.** No new `SensorPermission` case — speed/course ride the location fix's existing authorization, and heading uses the same when-in-use authorization CoreLocation requires for heading updates.
- **Display formatting is NOT wired to the existing `LengthUnit` (feet/meters) toggle.** `altitude`'s report-detail row already hardcodes feet regardless of that setting (pre-existing behavior, out of scope here) — speed/course/heading rows follow the same hardcoded-imperial precedent (mph, degrees) rather than introducing new wiring inconsistent with the rest of the screen. Flagged as a pre-existing tech-debt item, not fixed by this plan.
- **No new SwiftData migration needed.** Three additive `Optional<Double>` properties on `Report` are lightweight-migration-safe, same as every prior additive sensor field.

## Observable Acceptance Criteria

- Settings → Sensors shows three new toggles in the **LOCATION & WEATHER** section — **Speed**, **Course**, **Heading** — each with `sensor-toggle-speed` / `sensor-toggle-course` / `sensor-toggle-heading` accessibility identifiers, alongside the existing Location/Weather/Elevation rows.
- The survey capture checklist shows **SPEED**, **COURSE**, and **HEADING** rows (`sensor-row-speed`, `sensor-row-course`, `sensor-row-heading`) that read "GETTING …" while pending, "… OFF" when disabled, "UNABLE TO DETECT …" when the fix has no valid reading, and a captured value (e.g. "12 MPH", "180°", "45°") once resolved.
- A filed report's detail screen shows **Speed**/**Course**/**Heading** sensor rows (mirroring the existing Altitude row) when those values were captured, absent when they weren't.
- CSV/Markdown/DayOne/V2 exports of a report with these values present include them (new CSV columns `speedMPS`/`courseDegrees`/`headingDegrees`, Markdown front-matter `speed_mps`/`course_degrees`/`heading_degrees`, DayOne body lines, V2 JSON fields) — verified by kit tests, not a UI pass.

## Global Constraints

- Kit changes are test-first: failing test → `swift test` red → implement → green, per task.
- Follow the `altitude` sensor's existing wiring exactly at every touch point (`SensorKind`, `SensorPayload`, `ReportBuilder`, `SensorFailureHint`, `SensorPermissions`, `SensorSettingsView`, `CaptureChecklistView`, `SurveyController`/`WatchProviders`, `ReportDetailView`/`MacReportDetailView`, all four exporters, `V2Importer`) so the new sensors are indistinguishable in shape from existing ones.
- One scoped commit per task; `swift test` green before every commit. This is a kit-first plan — simulator-heavy UI verification (XCUITest, screenshot review) is explicitly deferred; App-target build correctness is verified via `xcodebuild build` (no launch), not a live simulator run.
- Do NOT touch signing/entitlements/branch-protection or the mac-ui-smoke workflow step.
- PR stays open for review; do not merge.

---

### Task 1: Kit — `MotionFormatting` (TDD)

**Files:**
- New: `Sources/DispatchKit/Capture/MotionFormatting.swift`
- New: `Tests/DispatchKitTests/MotionFormattingTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `MotionFormatting.validSpeed(_ metersPerSecond: Double) -> Double?`
- `MotionFormatting.validCourse(_ degrees: Double) -> Double?`
- `MotionFormatting.mph(fromMPS metersPerSecond: Double) -> Double`
- `MotionFormatting.compassPoint(forDegrees degrees: Double) -> String`

- [x] Failing tests: negative speed/course degrade to nil, zero/positive pass through unchanged; mph conversion factor pinned; compass point for 0/90/180/270/348.75 degrees (wraparound) resolves N/E/S/W/N.
- [x] Implement (pure, no imports beyond Foundation). `swift test` green.
- [x] Commit `feat(kit): MotionFormatting — speed/course validity + mph/compass conversions (plan 44, #61)`.

### Task 2: Kit — `SensorKind`, `SensorPayload`, `Report`, `ReportBuilder` (TDD)

**Files:**
- Modify: `Sources/DispatchKit/Capture/SensorSettings.swift` (`SensorKind` gains `.speed, .course, .heading`)
- Modify: `Sources/DispatchKit/Capture/SensorProvider.swift` (`SensorPayload` gains `.speed(Double)`, `.course(Double)`, `.heading(Double)`)
- Modify: `Sources/DispatchKit/Models/Report.swift` (`speedMPS`, `courseDegrees`, `headingDegrees: Double?`)
- Modify: `Sources/DispatchKit/Capture/ReportBuilder.swift` (payload → report field mapping)
- Modify: `Sources/DispatchKit/Capture/SensorFailureHint.swift` (labels + generic-fallback hint for the three new kinds)
- Modify: `Sources/DispatchKit/Capture/SensorPermissions` mapping is App-side (Task 4) — kit has no permission enum.
- Test: extend `Tests/DispatchKitTests/ReportBuilderTests.swift`, `Tests/DispatchKitTests/SensorFailureHintTests.swift`

- [x] Failing test: `ReportBuilder.save` with `.speed`/`.course`/`.heading` captured outcomes produces a `Report` with matching `speedMPS`/`courseDegrees`/`headingDegrees`; failing test for `SensorFailureHint.hint`/`disabledHint` on the new kinds (generic-fallback bucket, same shape as altitude/battery/connection/media).
- [x] Implement. `swift test` green.
- [x] Commit `feat(kit): speed/course/heading SensorKinds + Report fields + failure hints (plan 44, #61)`.

### Task 3: Kit — capture providers (TDD via mocks + `CaptureCoordinator`)

**Files:**
- Modify: `Shared/Providers/LocationProvider.swift` (`SpeedFromLocationProvider`, `CourseFromLocationProvider`, `HeadingProvider`)
- Test: extend `Tests/DispatchKitTests/CaptureCoordinatorTests.swift` with stub-provider coverage for the degrade-to-unavailable path (invalid speed/course) using `SensorPayload.speed`/`.course` directly — the CoreLocation-backed providers themselves are exercised by the App-target build only (no CoreLocation in kit tests), matching `AltitudeFromLocationProvider`'s existing precedent.

- [x] Failing test: a stub provider yielding `.speed(-1)`/`.course(-1)` — verify the *kit-level* MotionFormatting-driven unavailable path a real provider would take (assert `MotionFormatting.validSpeed(-1) == nil` drives `.unavailable`, exercised via a small in-kit provider wrapper if needed) — keep this scoped to what's testable without CoreLocation.
- [x] Implement `SpeedFromLocationProvider`/`CourseFromLocationProvider` (await `LocationFixStore`, degrade via `MotionFormatting`) and `HeadingProvider` (own `CLLocationManager`, `headingAvailable()` gate, single-sample delegate capture, `stopUpdatingHeading()` after resolving).
- [x] `swift test` green (kit-level assertions only; CoreLocation providers verified by App build in Task 4/6).
- [x] Commit `feat(kit): speed/course/heading capture providers (plan 44, #61)`.

### Task 4: App — provider wiring, settings, permissions, checklist, mocks

**Files:**
- Modify: `App/Sources/Survey/SurveyController.swift` (`providers(since:)` list + `MockProviders.all`)
- Modify: `App/Sources/Privacy/SensorPermissions.swift` (`.speed, .course, .heading: .location`)
- Modify: `App/Sources/Settings/SensorSettingsView.swift` (displayName cases, LOCATION & WEATHER category membership)
- Modify: `App/Sources/Survey/CaptureChecklistView.swift` (rows array, `captured(_:label:)` formatting)
- Modify: `App/Sources/Reports/ReportDetailView.swift` (sensor rows)

- [x] Wire providers into `SurveyController.providers(since:)` (after `AltitudeFromLocationProvider`) and add deterministic mocks (e.g. `Mock(kind: .speed, payload: .speed(5.5))`) to `MockProviders.all` so `--mock-sensors` checklist rows never spin.
- [x] `SensorPermissions.swift`: extend the exhaustive switch with `.speed, .course, .heading: .location`.
- [x] `SensorSettingsView.swift`: `displayName` cases ("Speed", "Course", "Heading"); add to the `LOCATION & WEATHER` category tuple.
- [x] `CaptureChecklistView.swift`: rows tuple entries + icon (`speedometer`, `location.north.line.fill`, `location.north.circle.fill` or similar) + `captured(_:label:)` cases formatting mph/degrees via `MotionFormatting`.
- [x] `ReportDetailView.swift`: sensor rows reading `report.speedMPS`/`courseDegrees`/`headingDegrees`, mirroring the altitude row's `append(...)` call shape.
- [x] Build: `xcodegen generate` (if needed) + `xcodebuild build` for the App scheme (no simulator launch) — confirms the exhaustive switches compile clean.
- [x] Commit `feat(app): wire speed/course/heading sensors into settings, checklist, report detail (plan 44, #61)`.

### Task 5: App — Mac report detail + Watch parity

**Files:**
- Modify: `Mac/Sources/MacReportDetailView.swift` (sensor rows, mirrors ReportDetailView)
- Modify: `Watch/Sources/WatchProviders.swift` (`watchCapableKinds` gains `.speed, .course` — NOT `.heading`; provider list; mocks; `watchDisplayName`)
- Modify: `App/Sources/Settings/WatchSettingsView.swift` if it enumerates kinds separately (check before editing)

- [x] `MacReportDetailView.swift`: add Speed/Course/Heading rows (Mac target is a phone-report viewer — heading may appear read-only from synced iPhone reports even though the Mac itself never captures it).
- [x] `WatchProviders.swift`: add `SpeedFromLocationProvider`/`CourseFromLocationProvider` to `watchCapableKinds` and the live provider list (after `AltitudeFromLocationProvider`); add mocks; extend `watchDisplayName`. Heading is deliberately absent (phone-only, per design decision).
- [x] `swift build`/relevant target build green.
- [x] Commit `feat(watch): speed/course sensors on watch capture (heading stays phone-only) (plan 44, #61)`.

### Task 6: Kit — export parity (CSV, Markdown, DayOne, V2)

**Files:**
- Modify: `Sources/DispatchKit/Export/CSVExporter.swift` (columns + row values)
- Modify: `Sources/DispatchKit/Export/MarkdownExporter.swift` (front matter + sensor lines)
- Modify: `Sources/DispatchKit/Export/DayOneExporter.swift` (sensor lines)
- Modify: `Sources/DispatchKit/V2/V2Models.swift` (`V2Report` fields)
- Modify: `Sources/DispatchKit/V2/V2Exporter.swift` (`reportDTO` mapping)
- Modify: `Sources/DispatchKit/Import/V2Importer.swift` (import mapping)
- Test: extend `Tests/DispatchKitTests/CSVExportTests.swift`, `Tests/DispatchKitTests/MarkdownExporterTests.swift`, add/extend a V2 round-trip test if one exists for altitude parity.

- [x] Failing tests: CSV header includes the new columns in the fixed position after `altitudeMeters`; a report with `speedMPS`/`courseDegrees`/`headingDegrees` set round-trips through the row; Markdown front matter emits `speed_mps`/`course_degrees`/`heading_degrees` when present.
- [x] Implement across all four exporters + V2 import. `swift test` green.
- [x] Commit `feat(kit): export parity for speed/course/heading across CSV/Markdown/DayOne/V2 (plan 44, #61)`.

### Task 7: Final verification + PR

- [x] Full `swift test` run, App-target build (`xcodebuild build`, no launch).
- [x] Open PR referencing #61; PR stays open for review, not merged.

## Completion note (2026-07-11)

All 7 tasks landed. `swift test`: 634 tests, all green. Builds verified: `DispatchApp` scheme (App + Watch + widgets, generic/iOS Simulator) and `DispatchMac` scheme, both `xcodebuild build` clean — no simulator launch, per the kit-first/deferred-UI-verification constraint. Simulator-launch/XCUITest verification (capture-checklist rows, settings toggles, report-detail rows actually rendering) is deferred to reviewer/follow-up, as scoped.
