# Dispatch Plan 5: Visualizations + State of Mind

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The home screen becomes Reporter's data face: swipeable per-question visualization pages (yes/no full-height stacked % bars, multi-choice distributions, number averages + line, token/people frequency, top places, note recents) with a filter bar — and mood-type questions write Apple Health State of Mind samples.

**Architecture:** DispatchKit gains `VisualizationData` (pure per-question aggregation) and `VisualizationFilterStore` — fully tested. The app renders them with Swift Charts on Home and adds the State of Mind write-through post-save (app layer, best-effort, HealthKit share auth for stateOfMind only).

**Spec:** `docs/superpowers/specs/2026-07-07-reporter-clone-design.md` §7 + §2 (stateOfMindKind) + §5 of Plan 4's deferred notes.

## Global Constraints

- Aggregations are pure DispatchKit functions over `[Report]`/`[Response]` — no SwiftUI/HealthKit imports in DispatchKit.
- Yes/No page: proportional stacked bars with % labels (option share of answered responses, skipped excluded), rendered full-height like the original.
- Question filter: persisted set of hidden question ids (UserDefaults, injectable suite); default = all visible.
- State of Mind: only questions with non-nil `stateOfMindKind` write samples; choice index maps linearly onto valence [-1.0, 1.0] (first choice = -1, last = +1; single choice = 0; Yes/No: Yes=+0.5, No=-0.5); sample UUIDs recorded into `report.stateOfMindSampleIDs`; ALL failures silent-but-logged (never block or fail a save); HealthKit share scope limited to stateOfMind. Gate the write under `--mock-sensors`/`--ui-testing` (no HK dialogs in tests).
- No delegation by implementers; suites stay green; commit + push per task; timestamped ledger discipline unchanged.

---

### Task 1: DispatchKit — VisualizationData + filter store

**Files:**
- Create: `Sources/DispatchKit/Visualization/VisualizationData.swift`
- Create: `Sources/DispatchKit/Visualization/VisualizationFilterStore.swift`
- Test: `Tests/DispatchKitTests/VisualizationDataTests.swift`

**Interfaces (contract):**
- `enum QuestionVisualization` with associated data:
  - `.optionShares([(option: String, share: Double)])` (yes/no + multi-choice; shares sum to 1.0 over answered responses; options ordered by the question's choices order, then any unlisted answered options by frequency)
  - `.numericSeries(points: [(date: Date, value: Double)], average: Double)`
  - `.frequency([(text: String, count: Int)])` (tokens + people, descending count then alphabetical, top 20)
  - `.places([(name: String, count: Int)])` (locationResponse text/venue grouped, top 20)
  - `.recentNotes([(date: Date, text: String)])` (newest first, top 20)
  - `.empty` (no answered responses)
- `VisualizationData.build(for question: Question, reports: [Report]) -> QuestionVisualization` — dispatches on question.type; joins responses by questionIdentifier first, prompt fallback when identifier nil (same rule as settings).
- `VisualizationFilterStore` (@Observable, init(defaults:)): `func isVisible(_ questionID: String) -> Bool` (default true), `func setVisible(_ questionID: String, _ visible: Bool)`; persisted as a hidden-ids string array.
- Tests: option shares math (2 yes, 1 no, 1 skipped → yes 2/3, no 1/3, options ordered Yes,No); numeric series sorted by date with correct average; token frequency ordering + tie alphabetical; empty → .empty; filter store default-visible + persistence round-trip.

TDD steps: RED → implement → GREEN → full suite → commit `feat: visualization aggregation and filter store` → push.

---

### Task 2: App — Home visualization pages + filter bar

**Files:**
- Create: `App/Sources/Visualizations/QuestionVisualizationView.swift`
- Create: `App/Sources/Visualizations/VisualizationFilterView.swift`
- Modify: `App/Sources/HomeView.swift`

**Requirements:**
- When reports exist: Home's center becomes a horizontally-paged TabView (`.page`, dots visible) of one page per visible enabled question (sortOrder order), each page: question prompt caps header + visualization: `.optionShares` → vertical stack of proportional bars, each option's bar height = share of available space, option name bottom-leading, "NN%" bottom-trailing, darker tint per index (full-bleed feel like the original); `.numericSeries` → Swift Charts LineMark + average label; `.frequency`/`.places` → ranked rows (text left, count right); `.recentNotes` → date + text rows; `.empty` → "No answers yet".
- A "Filter Visualizations…" pill at top (identifier `viz-filter-button`) → sheet listing all enabled questions with visibility toggles (VisualizationFilterStore, identifier `viz-filter-list`).
- When NO reports exist: hexagon empty-state stays exactly as-is.
- Hexagon: when reports exist, shrink it into the top bar area or omit (latitude — keep REPORT/awake bar and identifiers untouched).
- Themed; existing identifiers and UI tests must keep passing.

Verification: build, 66+ kit tests, UI suite green. Commit `feat: home visualization pages with filter` → push.

---

### Task 3: App — State of Mind write-through

**Files:**
- Create: `App/Sources/Health/StateOfMindWriter.swift`
- Modify: `App/Sources/Survey/SurveyController.swift` (post-save hook)
- Modify: `App/Sources/Settings/QuestionEditorView.swift` (mapping toggle)
- Modify: `App/Dispatch.entitlements` only if needed (share access already covered by healthkit entitlement)

**Requirements:**
- QuestionEditorView: for .multipleChoice and .yesNo questions, a "Log as State of Mind" toggle setting `question.stateOfMindKind` ("momentaryEmotion" when on, nil when off) — one-line footer explaining it logs to Apple Health.
- `StateOfMindWriter.write(for report: Report, in questions: [Question]) async` — for each answered response whose question has stateOfMindKind: valence per Global Constraints; `HKStateOfMind(date: report.date, kind: .momentaryEmotion, valence: valence, labels: [], associations: [])`; request share authorization for `HKObjectType.stateOfMindType()` on first use; save via HKHealthStore; append sample UUID strings to `report.stateOfMindSampleIDs` and save context. Every failure path logs and returns quietly.
- SurveyController.save: after ReportBuilder.save succeeds, fire-and-forget `Task { await StateOfMindWriter...(gated off under test args) }`.
- Purpose string: extend the existing health usage description to mention logging State of Mind.

Verification: build, kit tests, UI suite (no new HK dialogs in tests). Commit `feat: State of Mind write-through` → push.

---

### Task 4: Wrap

- Any straggler fixes; run all three suites; update the plan-sequence note in this file if scope changed.
- Commit `chore: plan 5 wrap` (only if changes) → push. Whole-branch review follows (controller-driven).
