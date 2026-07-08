# Dispatch Plan 9: Tester Experience (permission cascade, workout names, async import, sensor hints)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fresh TestFlight install works perfectly from report #1: permissions requested during onboarding (no first-capture dialog storm), workouts readable, imports responsive with progress, and failed sensors explain themselves.

**Context:** Born from real device testing (2026-07-08): the first report lost most sensors to the permission-dialog pile-up racing the 10s capture timeout; `workout.13` shipped in an export; imports run synchronously on the main actor; "UNABLE TO DETECT X" gives no guidance.

## Global Constraints

- No delegation by implementers; suites green (106 kit + 6 UI) before every commit; commit + push per task; scoped staging when tasks overlap files.
- All permission requests remain test-gated (`--mock-sensors`/`--ui-testing` → no dialogs, instant no-ops) — the UI suites must stay green.
- Data formats unchanged: `workout.<raw>` stays the STORED type string (display-time mapping only); ImportSummary shape unchanged.

---

### Task 1: Onboarding permission cascade

**Files:** Modify `App/Sources/OnboardingView.swift`, `App/Sources/DispatchApp.swift` (or a new `App/Sources/Privacy/PermissionCascade.swift`), `App/Sources/Settings/SensorSettingsView.swift`.

**Contract:**
- New `PermissionCascade` (@MainActor): `func requestAll() async` — sequentially (dialogs must not stack): location whenInUse (CLLocationManager.requestWhenInUseAuthorization; wait for status change or proceed after short bound), HealthKit read auth (`HealthKitReader.authorize()`), microphone (`AVAudioApplication.requestRecordPermission()`), photos (`PHPhotoLibrary.requestAuthorization(for: .readWrite)`), Focus (`INFocusStatusCenter.requestAuthorization`), notifications (existing scheduler path). Every step failure-tolerant and test-gated. Sequential ordering documented.
- Onboarding sensors page ("Embrace your sensors."): its primary action becomes "Enable Sensors" (identifier `onboarding-enable-sensors`) which runs the cascade with a small running indicator, then auto-advances to the next page. Skippable (page swipe still works; copy notes they can enable later in Settings).
- SensorSettingsView gains a "Request Sensor Access…" row (identifier `request-sensor-access`) running the same cascade — the path for existing installs and post-onboarding changes.
- Existing UI tests unaffected (`--skip-onboarding` unchanged; cascade never fires in test mode).

Verify: build, kit suite, UI suite. Commit `feat: onboarding permission cascade` → push.

### Task 2: Human-readable workout names

**Files:** Create `Sources/DispatchKit/Visualization/WorkoutActivityName.swift` + test; modify `App/Sources/Reports/ReportDetailView.swift` (and the capture checklist if it renders workout rows).

**Contract:**
- `WorkoutActivityName.displayName(forRawValue: UInt) -> String` — pure DispatchKit mapping (NO HealthKit import; a switch over the documented HKWorkoutActivityType raw values, ~80 cases, sourced from the SDK header enumeration; unknown → "Workout (<raw>)"). Also `displayName(forHealthType: String) -> String?` parsing the stored `workout.<raw>` form.
- DispatchKit tests: several known raw values (verify against the SDK header, e.g. running/walking/strength variants), the `workout.<raw>` parser, unknown-value fallback.
- ReportDetailView health rows render "Traditional Strength Training — 12m 31s" style instead of `workout.13`; duration formatted m/s.

Verify: kit suite (+ new tests), build, UI suite. Commit `feat: readable workout names` → push.

### Task 3: Async import with progress

**Files:** Modify `App/Sources/Settings/DataSettingsView.swift`.

**Contract:**
- Import moves off the main actor: read file + `V1Importer`/`V2Importer` + `VocabularyBuilder.rebuild` run in a background task with a background `ModelContext(container)` (verify SwiftData cross-context visibility — save on background context, main @Query refreshes; if that proves unreliable, fall back to main-actor import chunked with `Task.yield()` and document why).
- UI: import button shows a ProgressView + disables Data-screen actions while running (identifier `import-progress`); summary alert unchanged; errors alerted.
- Spotlight rebuildAll after import stays, moved off main where safe.

Verify: build, kit suite, UI suite. Commit `feat: async import with progress` → push.

### Task 4: Sensor failure hints + wrap

**Files:** Modify `App/Sources/Survey/CaptureChecklistView.swift`, `App/Sources/Survey/SurveyController.swift` (expose reasons), possibly `Sources/DispatchKit/Capture/` if a reason-mapping helper fits kit-side.

**Contract:**
- "UNABLE TO DETECT <X>" rows become tappable, revealing a one-line hint (inline expansion or footnote): map SensorKind + failure reason → actionable text (health kinds → "Check Health → Data Access for Dispatch"; location → "Allow location access in Settings"; weather timeout → "Check your connection"; generic → the captured reason string). Mapping is a pure function (kit or app — implementer's call) WITH tests if kit-side.
- Disabled sensors ("<X> OFF") hint at Settings → Sensors.
- Wrap: run all suites; update the plan-sequence note in the Plan 8 doc if stale.

Verify: build, kit suite, UI suite. Commit `feat: sensor failure hints` → push. Whole-branch review follows (controller-driven).
