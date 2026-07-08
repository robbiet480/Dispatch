# Dispatch Plan 11: Reporter parity from screenshot wave 2 (IMG_3273–3287)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the audited gaps between Dispatch and the original Reporter shown in the 2026-07-08 screenshot drop: per-question visualization choice, number default answers, a real multiple-selection flag with a proper options editor, wake/day/sleep chips, a genuine content-filter system for home visualizations, the tokens "N ANSWERS" viz, a discard confirmation, and the report-detail title format.

**Audit evidence (2026-07-08):** `Question` (Sources/DispatchKit/Models/Question.swift:5-27) has no `visualization`, `defaultAnswer`, or multi-select flag; viz is hard-coded by type in VisualizationData.swift:50-62; the filter sheet only hides questions (VisualizationFilterStore keys on question IDs); SurveyFlowView.swift:78 CANCEL dismisses without confirmation; ReportDetailView title is "HH:mm" only; choices editing is inline with no reorder; multipleChoice is always multi-select, yesNo always single (QuestionPageView.swift:53-57).

**Deliberate non-goals (decide + log):** flights-descended capture (original's "2 DOWN") — we intentionally use HealthKit (`flightsClimbed` has no descended counterpart; CoreMotion's CMPedometer would add a new Motion permission). Backlogged, not in this plan. The capture checklist already covers the "GETTING X…" screen (item 8) and proportion bands/graph exist (7a/7c) — no work there.

## Global Constraints

- No delegation by implementers; suites green (139 kit + 6 UI at plan start) before every commit; commit + push per task; `git pull --rebase` before starting and pushing.
- **Schema discipline:** new Question fields are additive and optional (CloudKit-compatible: optional or defaulted, no #Unique). v2 export gains fields; v2 import tolerates their absence (old exports still import); round-trip tests updated to cover both presence and absence. `schemaVersion` stays 2.
- Survey behavior defaults preserve today's semantics unless the new flag says otherwise (existing questions must not change behavior on migration).

---

### Task 1: Kit — Question fields + schema + viz override

**Files:** `Sources/DispatchKit/Models/Question.swift`, `Sources/DispatchKit/V2/*` (exporter/importer/DTOs), `Sources/DispatchKit/Visualization/VisualizationData.swift`, tests.

**Contract:**
- Question gains: `visualizationRaw: String?` (nil = automatic-by-type; values "proportion", "graph", "frequency"), exposed as `enum QuestionVisualization: String { proportion, graph, frequency }` + `var visualization: QuestionVisualization?`; `defaultAnswerString: String?` (number questions: value applied when the user leaves the answer empty); `allowsMultipleSelectionRaw: Bool?` exposed as `var allowsMultipleSelection: Bool` defaulting **true** for `.multipleChoice` (today's behavior) and false otherwise.
- v2 DTOs/exporter/importer: include the three fields when set; importing v2 files without them yields nil/defaults. Round-trip tests: with values, without values (old fixture unchanged must still pass byte-identical v1→v2→v2 guarantees — the new fields are omitted when nil, so old flows are unaffected; add an explicit test asserting nil fields don't appear in exported JSON).
- `VisualizationData.build`: honor `question.visualization` override when compatible (proportion valid for yesNo/multipleChoice; graph for number; frequency for tokens/people; incompatible/nil → current type-based default). Tests for override + incompatible fallback.

Verify: `swift test` all green. Commit `feat(kit): question visualization, default answer, multi-select flag` → push.

### Task 2: App — question editor parity

**Files:** `App/Sources/Settings/QuestionEditorView.swift` (+ new subviews/files as needed), `App/Sources/Survey/QuestionPageView.swift`, `App/Sources/Survey/SurveyViewModel`-adjacent save path if default-answer application lands there (grep; prefer kit-side in ReportBuilder/SurveyViewModel where empties currently become `.skipped`).

**Contract:**
- **Schedule chips:** replace the SHOW ON checklist with three inline capsule chips — "WAKE" (sun-rise icon), "DAY" (sun icon, maps to `.regular`), "SLEEP" (moon icon) — multi-select toggle behavior, filled when selected, ≥1 enforced as today. Identifiers `schedule-wake`, `schedule-day`, `schedule-sleep`.
- **Visualization picker:** "VISUALIZATION" row for applicable types (yesNo/multipleChoice → Proportion; number → Graph; tokens/people → Frequency; show the type's valid options + the automatic default). Writes `question.visualization`.
- **Default answer:** for `.number` questions, "DEFAULT ANSWER" field, placeholder "Value for empty responses", numeric keyboard, writes `defaultAnswerString`. On survey save, an empty number answer with a non-nil default files that value instead of `.skipped` (kit-side logic + kit test).
- **Multi-choice options editor:** "EDIT ▸" affordance on the Multi-Choice type row (and/or a CHOICES → "Add an option…" drill-in) opening a dedicated screen: List with drag-reorder (`.onMove`), swipe-delete, "ADD AN OPTION…" row, and a "MULTIPLE SELECTIONS" Allowed/Not Allowed picker bound to `allowsMultipleSelection`. Identifiers `choice-editor`, `add-option`, `multiple-selections`.
- **Survey honors the flag:** `QuestionPageView` passes `multiSelect: question.allowsMultipleSelection` for multipleChoice (yesNo stays single). ChoiceListView single-select mode for multipleChoice-with-flag-off replaces selection instead of appending.
- Existing UI tests must stay green — check for tests touching the editor's SHOW ON rows or choices UI and update them honestly to the new identifiers (do not delete coverage).

Verify: build, kit suite, UI suite. Commit `feat: question editor parity — chips, viz picker, default answer, options editor` → push.

### Task 3: App + kit — visualization content filters

**Files:** new `Sources/DispatchKit/Visualization/ReportFilter.swift` + tests; `App/Sources/UIState/` or kit `VisualizationFilterStore` extension; `App/Sources/Home/VisualizationFilterView.swift` (or current sheet file), `App/Sources/HomeView.swift`.

**Contract:**
- Kit `ReportFilter`: `enum FilterCriterion` covering People (person name), Places (place name), Tokens (token text), Months (1-12), Years, Ambient Audio (bucket: quiet/moderate/loud — reuse the AudioLevel label thresholds), Steps (bucket: <5k, 5k–10k, >10k), Weather (condition string). `ReportFilter.matches(report:criteria:) -> Bool` — ALL criteria must match (the original's "Results are only shown for entries matching all filters."). Pure + tested (one test per criterion kind + a match-all combination test).
- Filter sheet rebuilt to match the original: search/summary field at top, category rows (People, Places, Tokens, Months, Years, Ambient Audio, Steps, Weather) drilling into value pickers populated from actual data (person/token vocab entities, distinct place names, distinct years, etc.), footer text "Results are only shown for entries matching all filters." Active criteria shown as removable chips in the top field. Keep the existing per-question show/hide as a separate "Questions" section at the bottom of the sheet (it's a useful Dispatch extra — do not delete it).
- HomeView: viz pages compute from `reports.filter { ReportFilter.matches($0, criteria) }`; active-filter state shows in the filter pill (e.g. "2 filters"). Criteria persist like the current store (UserDefaults) and survive relaunch.
- Perf: filtering runs where the viz data already builds (memoized path from P7 T0) — no per-frame filtering.

Verify: build, kit suite (+ new tests), UI suite. Commit `feat: visualization content filters` → push.

### Task 4: App — survey/detail polish + tokens viz + wrap

**Files:** `App/Sources/Survey/SurveyFlowView.swift`, `App/Sources/Visualization/QuestionVisualizationView.swift` (RankedRowsView area), `App/Sources/Reports/ReportDetailView.swift`, `AppUITests/` as needed.

**Contract:**
- **Discard confirmation:** CANCEL presents "Are you sure you want to discard this report?" with Cancel / Discard (destructive); Discard dismisses. Update UI tests that tap `survey-cancel` to handle the alert (keep at least one test asserting the alert appears — honest coverage, not weakening).
- **Tokens/people viz style:** frequency page renders the original's layout — large count numeral + small-caps "ANSWERS" label, then a comma-joined wrapping list "Token (count), Token (count), …" (counts de-emphasized). Replaces RankedRowsView for tokens/people (places keeps ranked rows).
- **Report detail title:** navigation title "MMM d, yyyy 'at' HH:mm" (e.g. "Dec 13, 2018 at 04:27"); keep the footer's full timestamp.
- Wrap: full suites; append plan-completion note to this doc.

Verify: build, kit suite, UI suite. Commit `feat: discard confirm, tokens viz, detail title` → push. Whole-branch review follows (controller-driven).

---

## Plan completion note (2026-07-08)

All four tasks shipped to main, one commit each:

- **T1** `c5e7846` — kit fields/schema/viz override. The style enum is named `VisualizationStyle` (not `QuestionVisualization` as sketched above) because that name was already taken by the aggregation result enum in VisualizationData.swift.
- **T2** `5a8f1ce` — editor parity: WAKE/DAY/SLEEP chips (`schedule-wake/day/sleep`), VISUALIZATION picker, DEFAULT ANSWER field (applied kit-side in `SurveyViewModel.drafts()`), `ChoiceOptionsEditorView` (`choice-editor`, `add-option`, `multiple-selections`; drag-reorder via toolbar EditButton edit mode, swipe-delete in default mode), survey honors `allowsMultipleSelection`.
- **T3** `883a7e4` — `ReportFilter` (8 criterion kinds, AND semantics, report-timezone month/year; `matches(report:criteria:peopleQuestionIDs:)` — the extra defaulted param scopes person criteria to people questions), criteria persistence on `VisualizationFilterStore`, rebuilt filter sheet with chips/category drill-ins/footer + Questions section kept, Home builds viz from matching reports inside the memoized `.task(id:)` path with criteria in the task id.
- **T4** — discard confirmation alert on survey CANCEL (UI test asserts the alert + Discard/Cancel buttons positively), `TokenFrequencyView` "N ANSWERS" layout for tokens/people (places keeps ranked rows), detail title "MMM d, yyyy 'at' HH:mm".

Suites at wrap: 158 kit tests (was 139), 6 UI tests, all green. `schemaVersion` remains 2; nil parity fields are omitted from v2 JSON (explicit test) and old exports import unchanged.
