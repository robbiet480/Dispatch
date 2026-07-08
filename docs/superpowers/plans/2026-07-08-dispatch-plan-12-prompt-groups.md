# Dispatch Plan 12: Prompt Groups, workout-end trigger, Activity Rings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (Angela's feature request, 2026-07-08):** group arbitrary prompts into **Prompt Groups**, each with its own Timed or Event notification schedule — one group every X hours (or at random intervals), another once a day, another when a workout ends. Plus: capture Apple Activity Ring status with every report.

## Design decisions (decide + log)

- **Groups are additive, not a migration.** Ungrouped questions keep today's exact behavior (reportKinds + the global schedule). A group's notification opens a survey scoped to that group's questions. No existing question, report, or schedule changes meaning on upgrade.
- **Membership by ID list, not SwiftData relationship.** `PromptGroup.questionIDs: [String]` (question uniqueIdentifiers, ordered) — CloudKit-safe (optional/defaulted, no #Unique), no relationship-migration risk, tolerant of dangling IDs (skipped at survey time).
- **Schedule kinds:** `everyNHours(n)` (fires on the hour-multiples within awake window), `timesPerDay(count, distribution)` (reuses the existing PromptPlanner random/semiRandom/regular machinery), `dailyAt(times)` (DateComponents list), `event(workoutEnd)`. One schedule per group.
- **Shared 64-pending budget:** global prompts plan first (existing behavior), then groups in creation order, nags last with the existing clamp — one allocator owns the arithmetic and logs what got clamped. Identifiers: `prompt-<stamp>` stays global; groups use `gprompt-<groupID>-<stamp>`; nags extend to cover both parents.
- **Workout-end trigger** uses `HKObserverQuery` on workout samples + HealthKit **background delivery** — requires the `com.apple.developer.healthkit.background-delivery` entitlement, which MUST be proven with a real archive before shipping (two hallucinated-entitlement incidents already; the pattern is: add, archive, codesign-dump, only then rely on it). On observer fire with a new workout end date since the last seen: post an immediate local notification for each workout-end group (respect awake state). Store last-seen workout end date in defaults to dedupe.
- **Activity Rings** = new `SensorKind.healthActivityRings`, captured via `HKActivitySummaryQuery` for the report's day: move actual/goal (kcal), exercise actual/goal (min), stand actual/goal (hours) — six numeric readings (`activity.move`, `activity.moveGoal`, …) so they stay viz-able; detail row renders "Move 320/500 · Exercise 22/30 · Stand 9/12". Degrades to unavailable when no summary (no watch).
- **Report attribution:** `Report.promptGroupID: String?` (additive, optional) + new `ReportTrigger.workoutEnd` raw value; v2 export includes both when set, import tolerates absence.

## Global Constraints

- No delegation by implementers; suites green (158 kit + 7 UI at plan start) before every commit; commit + push per task; `git pull --rebase` before starting and pushing. Pushing to main is the repo owner's standing instruction.
- Schema discipline as Plan 11: additive optional fields only, nils omitted from export JSON (tests), old exports import unchanged, schemaVersion stays 2, CloudKit rules hold.
- All scheduling/observers test-gated (`--mock-sensors`/`--ui-testing` → no-ops). Entitlements archive-proven before relied upon.
- New editor text fields follow the local-@State pattern (LocalTextEditorField doc comment) — no per-keystroke observable writes.

---

### Task 1: Kit — PromptGroup model + schema

**Files:** new `Sources/DispatchKit/Models/PromptGroup.swift`; `Sources/DispatchKit/Models/Report.swift` (+promptGroupID), `Values.swift` (ReportTrigger.workoutEnd); `Sources/DispatchKit/V2/*`; tests.

**Contract:**
- `@Model PromptGroup`: `uniqueIdentifier: String` (UUID string, defaulted), `name: String` (defaulted ""), `questionIDs: [String]` (defaulted []), `scheduleKindRaw: String` (defaulted), `scheduleHours: Int?`, `scheduleCount: Int?`, `scheduleDistributionRaw: String?`, `scheduledTimesJSON: String?`, `isEnabled: Bool` (defaulted true), `sortOrder: Int` (defaulted 0). Exposed `var schedule: GroupSchedule` (enum with associated data as designed above; unknown raw → disabled).
- `Report.promptGroupID: String?`; `ReportTrigger` gains `.workoutEnd` (verify raw-value stability with existing stored/exported values — additive case only).
- v2 export: `promptGroups` array + report `promptGroupID`/trigger; nil/empty omitted; import tolerates absence; dedupe groups by uniqueIdentifier on import (same pattern as questions). Round-trip tests both ways + old-fixture unchanged.

Verify: `swift test`. Commit `feat(kit): PromptGroup model + schema` → push.

### Task 2: Kit — group planning + shared budget allocator

**Files:** new `Sources/DispatchKit/Prompting/GroupPlanner.swift`, `Sources/DispatchKit/Prompting/NotificationBudget.swift`; extend `PromptPlanner` only if needed; tests.

**Contract:**
- `GroupPlanner.plan(group:, awakeStart:, awakeEnd:, seed:, calendar:) -> [Date]`: everyNHours → hour multiples from awakeStart within window; timesPerDay → delegate to PromptPlanner with the group's distribution (seed varied by groupID hash so groups don't fire simultaneously); dailyAt → the times within window; event → [] (not timer-planned). Pure, deterministic, tested per kind + day-rollover edge.
- `NotificationBudget.allocate(globalCount:, groupCounts:[(id, count)], nagRequest:(delay, interval, maxCount), cap: 64) -> allocations`: global first, groups in order, nags last (existing clamp math folded in), everything ≥ 0, total ≤ cap. Tests: overflow trimming order, zero cases, nag interaction.

Verify: `swift test`. Commit `feat(kit): group planner + shared notification budget` → push.

### Task 3: App — scheduler wiring + group survey scoping

**Files:** `App/Sources/Notifications/NotificationScheduler.swift`, `App/Sources/SurveyPresenter.swift` (SurveyRequest), `Sources/DispatchKit/Capture/SurveyViewModel.swift` (question filtering), `App/Sources/Survey/SurveyFlowView.swift`/`SurveyController` as needed.

**Contract:**
- `replanNow` additionally: fetch enabled timer-scheduled groups, plan via GroupPlanner, allocate via NotificationBudget, schedule `gprompt-<groupID>-<stamp>` requests whose content body names the group (title "Time to report", body = group name or its first question's prompt). Removal batch extends to `gprompt-` prefix (both awake/asleep paths). Nag chains cover group prompts too (parent stamp embeds group).
- Notification userInfo carries `promptGroupID`; delegate default-tap creates `SurveyRequest(kind: .regular, trigger: .notification, promptGroupID:)`; quick-answer actions still file against the global Yes/No question ONLY for global prompts (group prompts get no quick-answer category if the group lacks a Yes/No question — keep it simple: group prompts use a plain category).
- Survey scoping: SurveyRequest.promptGroupID → SurveyController/SurveyViewModel filters questions to the group's questionIDs (ordered per the group; dangling IDs skipped); saved report records promptGroupID.
- `reportFiled`/lastActedAt semantics unchanged and apply to group prompts.

Verify: build, kit suite, UI suite. Commit `feat: per-group notification scheduling + scoped surveys` → push.

### Task 4: App — Prompt Groups editor UI

**Files:** new `App/Sources/Settings/PromptGroupsView.swift` (+ editor subview); `App/Sources/Settings/SettingsView.swift` (entry row).

**Contract:**
- Settings → "Prompt Groups": list (name, schedule summary, enabled toggle), add/delete/reorder. Editor: name field, question membership (multi-select from enabled questions, ordered), schedule picker — Timed (Every N hours stepper | N times per day + distribution | Daily at times editor) or Event (When a workout ends), enabled toggle. Every change triggers replan. Identifiers: `prompt-groups`, `group-add`, `group-name`, `group-schedule-kind`, `group-questions`.
- Empty-state copy explaining the feature. One new UI test: create a group, assign a question, verify it appears in the list (test-gated scheduling means no dialogs).

Verify: build, kit suite, UI suite (7+1). Commit `feat: prompt groups editor` → push.

### Task 5: App — workout-end trigger + Activity Rings capture

**Files:** new `App/Sources/Providers/WorkoutEndObserver.swift`; `App/Sources/Providers/HealthProviders.swift` (+rings), `Sources/DispatchKit/Capture/SensorSettings.swift` (+`healthActivityRings`), `App/Dispatch.entitlements`, `App/Sources/Survey/CaptureChecklistView.swift`, `App/Sources/Reports/ReportDetailView.swift`, `App/Sources/Privacy/PermissionCascade.swift` (rings read type).

**Contract:**
- **Entitlement first:** add `com.apple.developer.healthkit.background-delivery`; prove via archive + codesign dump (commands as in prior plans, team UTQFCBPQRF). If rejected: workout-end groups still work via foreground observer only; document loudly.
- `WorkoutEndObserver` (test-gated): HKObserverQuery on `HKObjectType.workoutType()` + `enableBackgroundDelivery(.immediate)`; on fire, query workouts ending after the persisted last-seen end date; if new and any enabled workout-end group exists and awake: post an immediate `gprompt-` notification per such group (reuse scheduler content path), update last-seen, call the observer's completion handler ALWAYS (missing it throttles background delivery). Started at app launch when any workout-end group is enabled; stopped otherwise.
- **Activity Rings:** `SensorKind.healthActivityRings` (settings toggle, default on), provider via `HKActivitySummaryQuery` for the report day's `DateComponents` (calendar-aware); readings `activity.move`/`activity.moveGoal`/`activity.exercise`/`activity.exerciseGoal`/`activity.stand`/`activity.standGoal`; `activitySummaryType` added to HealthKit read types + cascade; checklist row "GETTING ACTIVITY RINGS…" → "MOVE 320/500 KCAL"; detail row "Activity — Move 320/500 · Exercise 22/30 · Stand 9/12". errorNoData → unavailable (not failure).
- **Triggering-workout details (amendment, user request):** when a workout-end notification fires, its userInfo carries the workout's HKObject UUID alongside promptGroupID; SurveyRequest carries it through; when present, capture fetches THAT workout and emits detailed readings — `workout.trigger.type` (raw value, same `workout.<raw>` display mapping), `workout.trigger.duration` (s), `workout.trigger.energy` (kcal, when present), `workout.trigger.distance` (m, when present), `workout.trigger.avgHeartRate` (bpm, when present). Report detail renders a "Triggered by" line above the sensor rows (e.g. "Running — 32m 10s · 412 kcal · 5.2 km · 148 bpm avg"), omitting absent metrics. Readings are additive strings/numerics — no schema change beyond what readings already allow. If the workout can't be re-fetched (deleted, permissions), degrade to the plain workoutEnd trigger with no extra readings.
- Kit tests for any pure mapping (reading construction/display formatting if kit-side, including the triggered-workout summary line formatter).

Verify: build, kit suite, UI suite, archive+codesign proof. Commit `feat: workout-end trigger + activity rings capture` → push.

### Task 6: Killed-fix-wave items + wrap

**Files:** per the build-5 review: `App/Sources/Visualizations/VisualizationFilterView.swift`, `App/Sources/Settings/ChoiceOptionsEditorView.swift`, `Sources/DispatchKit/Visualization/ReportFilter.swift`, `App/Sources/HomeView.swift`, `App/Sources/Settings/QuestionEditorView.swift`.

**Contract (from the build-5 review, previously dispatched then stopped):**
1. Filter chip/memo identity: chips identified by criterion (kind-aware), not displayText; memoKey from canonical criterion encoding (`FilterCriterion.canonicalKey` in kit + test).
2. Editable choice options: in-place TextField rows (local-draft, commit on submit; empty keeps old), stable ForEach identity for `.onMove`.
3. Token filter excludes people-question responses via `peopleQuestionIDs` (+ kit test).
4. Default-answer persisted only when `Double(trimmed)` parses.
5. Filter sheet vocab fetched once into @State, not per render.
- Wrap: full suites; completion note appended to this doc.

Verify: build, kit suite, UI suite. Commit `fix: filter chip identity, editable options, review minors` → push. Whole-branch review follows (controller-driven).

---

## Completion note (2026-07-08)

All six tasks landed on main, one scoped commit each:
1. `03973ba` feat(kit): PromptGroup model + schema — GroupSchedule enum (unknown raw → disabled), Report.promptGroupID, v2 `promptGroups`/`promptGroupID` omitted when nil/empty, dedupe-by-ID import. `ReportTrigger.workoutEnd` already existed (shipped pre-plan); no raw-value change needed.
2. `f97e825` feat(kit): GroupPlanner (per-kind planning, FNV-1a group-varied seeds, midnight-crossing dailyAt) + NotificationBudget allocator (global → groups in order → nags, legacy clamp parity test).
3. `ddb9328` feat: scheduler plans enabled timer groups per awake window, `gprompt-<groupID>-<stamp>` requests, gprompt- removals in the SAME batch as prompt-/nag-, nag chains cover group parents (stamp embeds groupID), group prompts use a plain category + userInfo promptGroupID, tap-through opens a group-scoped survey (ordered questionIDs, dangling skipped), report records promptGroupID.
4. `23107e2` feat: Settings → Prompt Groups editor (list/add/delete/reorder/enable, schedule picker for all four kinds, ordered question membership, empty-state copy, replan on every change) + 8th UI test.
5. `5b1ce77` feat: `com.apple.developer.healthkit.background-delivery` entitlement PROVEN via device archive + codesign dump BEFORE reliance; WorkoutEndObserver (HKObserverQuery + immediate background delivery, completion handler called on every path, last-seen dedupe, awake-gated, test-gated); Activity Rings sensor (six `activity.*` readings, errorNoData → unavailable, checklist + detail rows); amendment: triggering workout's `workout.trigger.*` readings + "Triggered by" detail line (pure kit formatter, degrades cleanly).
6. (this commit) fix: criterion-keyed filter chips + kit `FilterCriterion.canonicalKey` memo keys, in-place editable choice options (stable UUID row identity, empty keeps old), token filter excludes people-question responses, default answer persisted only when numeric, filter-sheet vocab fetched once per appear.

Suites at wrap: 194 kit tests, 8 UI tests, sim build clean — all green.
