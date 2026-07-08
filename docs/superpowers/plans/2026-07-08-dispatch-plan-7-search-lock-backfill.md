# Dispatch Plan 7: Search + Spotlight, App Lock, Backfill

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find anything (in-app search over notes/tokens/people/places + CoreSpotlight system indexing), protect everything (Face ID app lock with background grace), and record the past (backdated reports via a date picker, `isBackdated`, no sensor capture).

**Scope decision (logged):** spec §3 allows backfill to capture "what HealthKit can answer historically" — v1 skips ALL sensor capture on backdated reports for simplicity; historical health backfill is backlog.

## Global Constraints

- Search matching is a pure DispatchKit function, case-insensitive, over: note text (textResponses), token texts, people tokens, location answer text, placemark locality/name. Tests required.
- Spotlight: index on report save + delete + import; item attributes: title = formatted date + place, contentDescription = joined note/token snippets; domain identifier `report`; identifier = report uniqueIdentifier. Deletion removes the item. No Spotlight in UI-test/mock mode.
- App lock: LocalAuthentication (.deviceOwnerAuthentication — biometics + passcode fallback); locks at launch when enabled and on returning from background after >60s away; PRIVACY settings section with toggle (auth required to ENABLE too); completely bypassed under `--ui-testing`/`--mock-sensors`.
- Backfill: "+" in the reports list toolbar (identifier `backfill-button`) → sheet with a compact date+time picker (max = now) → CONTINUE presents the normal survey flow for kind .regular, trigger .manual, at the chosen date with `isBackdated = true` and NO sensor capture; report detail shows a "BACKDATED" chip.
- SurveyRequest/SurveyController/ReportBuilder thread an optional `overrideDate: Date?` through; when set: report.date = overrideDate, isBackdated = true, capture skipped (empty outcomes).
- No delegation; suites green; commit+push per task; timestamped ledger.

---

### Task 0: Carried from Plan 5 review — viz memoization + polish

**Files:**
- Modify: `App/Sources/HomeView.swift`
- Modify: `Sources/DispatchKit/Visualization/VisualizationData.swift` (blank place-name fallback only)
- Modify: `AppUITests/NavigationUITests.swift` (or new file)

**Contract:**
- Memoize visualization building: cache `[String: QuestionVisualization]` in view state, recomputed via `.task(id:)` (or equivalent) keyed on (reports count, newest report date, filter/hidden-ids state, enabled-question ids) — NOT rebuilt on unrelated re-renders (theme/awake changes). The existing `QuestionVisualization: Equatable` conformance is the tool for cheap change detection.
- While in HomeView: give the viz TabView a `@State` selection keyed by question id so page position survives data changes.
- Places: a venue-grouped place whose responses all lack text falls back to "Unknown place" (never an empty row) — DispatchKit + test.
- Filter-sheet UI test: tap `viz-filter-button`, toggle a question off in `viz-filter-list`, assert its page disappears (page count or prompt-text existence).

Verify: kit suite, build, UI suite (3 UI tests now). Commit `perf: memoize home visualizations + filter UI test` → push.

### Task 1: DispatchKit — ReportSearch + backdate plumbing

**Files:**
- Create: `Sources/DispatchKit/Search/ReportSearch.swift`
- Modify: `Sources/DispatchKit/Capture/ReportBuilder.swift` (overrideDate/isBackdated parameters)
- Test: `Tests/DispatchKitTests/ReportSearchTests.swift` (+ extend ReportBuilderTests)

**Contract:**
- `ReportSearch.matches(_ report: Report, query: String) -> Bool` and `ReportSearch.filter(_ reports: [Report], query: String) -> [Report]` — trimmed, case/diacritic-insensitive substring match across the Global Constraints field list; empty query → all.
- `ReportBuilder.save(kind:trigger:date:timeZone:outcomes:answers:in:isBackdated:)` — new defaulted `isBackdated: Bool = false` parameter setting the model flag (date is already a parameter — callers pass the override).
- Tests: matches note text, token, person, place text, locality; case-insensitive; non-matching query excluded; empty query returns all; builder test asserting isBackdated flag persists.

TDD → commit `feat: report search and backdate plumbing` → push.

### Task 2: App — search bar + Spotlight indexing

**Files:**
- Create: `App/Sources/Search/SpotlightIndexer.swift`
- Modify: `App/Sources/Reports/ReportsListView.swift` (.searchable using ReportSearch.filter)
- Modify: save/delete/import call sites to index/deindex (SurveyController.save post-save; ReportsListView delete)

**Contract:** search field filters sections live (identifier `reports-search`); SpotlightIndexer (CSSearchableIndex) per Global Constraints, gated off in test/mock mode; failures log-and-continue.

Verify: build, kit suite, UI suite. Commit `feat: report search and Spotlight indexing` → push.

### Task 3: App — Face ID app lock

**Files:**
- Create: `App/Sources/Privacy/AppLock.swift` (@Observable store + gate view)
- Modify: `App/Sources/ContentView.swift` (gate overlay), `App/Sources/DispatchApp.swift` (scenePhase tracking), `App/Sources/Settings/SettingsView.swift` (PRIVACY section)

**Contract:** per Global Constraints; lock UI = themed full-screen cover with app name + "Unlock" button triggering LAContext.evaluatePolicy; toggle in PRIVACY section (identifier `app-lock-toggle`) requires successful auth to enable; disabled/absent biometrics degrade to passcode; store on appDefaults.

Verify: build, suites (lock bypassed in tests). Commit `feat: Face ID app lock` → push.

### Task 4: App — backfill + wrap

**Files:**
- Modify: `App/Sources/Reports/ReportsListView.swift` (toolbar `backfill-button` + picker sheet)
- Modify: `App/Sources/SurveyPresenter.swift` (SurveyRequest.overrideDate), `App/Sources/Survey/SurveyFlowView.swift` + `SurveyController.swift` (skip capture when overrideDate set; pass date+isBackdated to save)
- Modify: `App/Sources/Reports/ReportDetailView.swift` (BACKDATED chip)

**Contract:** per Global Constraints. Then run all three suites; commit `feat: backdated reports` → push. Whole-branch review follows (controller-driven).
