# Dispatch Plan 43: Siri Shortcuts / App Intents (report-centric)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal (issue #59):** Dispatch's App Intents today are widget/control plumbing
only — `QuickAnswerIntent` (widget Yes/No buttons, `isDiscoverable = false`)
and `StartReportControlIntent` (Control Center `OpenIntent`). Neither shows up
in the Shortcuts app as a first-class, parameterized action. This plan promotes
that machinery to a **user-visible, scriptable** surface: file a report
(optionally scoped to a prompt group), log a single question→value answer into
a **real report**, toggle awake/asleep, and three **query** intents (today's
report count, current streak, last answer to a question) usable in Shortcuts
logic and interactive widgets — plus donation phrases for Spotlight/Siri.

**SCOPE CONSTRAINT — report-centric (issue #59, hard rule):** answers only ever
exist *inside* reports. There is no free-floating "answer" intent or entity.
The "log an answer" action creates a REAL `Report` (through the shared
`ReportBuilder` path, `trigger .intent`) whose sole content is the supplied
answer — exactly the domain rule `QuickAnswerIntent` already follows. This plan
generalizes that single-question Yes/No filer to any question type, keeping the
"answer lives in a report" invariant.

## Architecture

Two layers, matching the app's existing intent design (`AppActions` bridge +
read-only shared-store queries):

1. **Kit backing (cross-platform, pure, `swift test`-covered)** — the logic an
   intent needs but that must not depend on `AppIntents` or a UI process:
   - `AnswerSummary` (`Sources/DispatchKit/Intents/AnswerSummary.swift`):
     `text(for:)` flattens one `Response` to a human string (the exporter
     precedence: tokens → options → location → time → numeric → note), and
     `lastAnswer(toQuestionID:in:)` finds the most recent non-draft report
     carrying an answered response for a question and returns `(text, date)`.
   - `IntentAnswerFiler` (`Sources/DispatchKit/Intents/IntentAnswerFiler.swift`):
     `coercedValue(forType:choices:raw:)` maps a raw Shortcuts string to the
     right `AnswerValue` for a question's type, and
     `file(questionID:raw:trigger:date:in:)` resolves an eligible question and
     files a one-answer report via `ReportBuilder.save` — the generalization of
     `QuickAnswerFiler.file`.
   Today's count and streak reuse the EXISTING kit math (`WidgetSnapshot`,
   `ReportStreak`) — no new wrappers.

2. **iOS App Intents (`App/Sources/Intents/`)** — thin `AppIntent` conformances
   over the kit:
   - `QuestionEntity` + `QuestionQuery` (`QuestionEntity.swift`): the
     parameterizable question, read from the shared App Group store READ-ONLY
     (the `PromptGroupEntity`/`SharedStoreReader` precedent).
   - `FileReportIntent` (evolves the old `StartReportIntent`): `openAppWhenRun`,
     optional `PromptGroupEntity` parameter → routes through
     `AppActions → SurveyPresenter` with a group-scoped `SurveyRequest`.
   - `LogAnswerIntent`: `QuestionEntity` + value `String` → files a real report
     via `IntentAnswerFiler`, opening the shared store WRITABLE from the intent
     process (the `QuickAnswerIntent` process contract), records the
     `WidgetQuickAnswerMarker` nag-cancel marker, enqueues the webhook, reloads
     widgets, and returns a spoken/displayed confirmation dialog.
   - `TodayReportCountIntent`, `CurrentStreakIntent`, `LastAnswerIntent`:
     read-only query intents returning a value AND a dialog.
   - `DispatchShortcuts` (`AppShortcutsProvider`): donation phrases for all of
     the above.

**Store-location wrinkle (logged):** the read/write store URL differs per
platform — iOS app + widgets and the watch use the App Group store
(`StoreLocation.appGroupURL()`); the Mac uses its own Application Support store.
The kit backing takes a `ModelContext` and is location-agnostic; the iOS intent
layer resolves the App Group store exactly as the widgets do.

## Tech Stack

App Intents (`AppIntent`, `AppEntity`, `EntityQuery`, `AppShortcutsProvider`,
`ProvidesDialog`, `ReturnsValue`) — cross-platform framework, per-target
registration. SwiftData read-only (`allowsSave: false`) for entity/query
providers and writable (`allowsSave: true, cloudKitDatabase: .none`) for the
log-answer filer, matching the probe-verified `QuickAnswerIntent` process
contract. DispatchKit pure value/`ModelContext` logic for the backing (no
`AppIntents` import in the kit).

## Design decisions (decide + log)

- **One generalized filer, not a new answer domain.** `IntentAnswerFiler.file`
  reuses `ReportBuilder.save` with a single `AnswerDraft`, `trigger .intent`.
  Rejected: a standalone "Answer" entity/record (violates the report-centric
  rule) and a second report-assembly path (duplicates `ReportBuilder`).
- **`LogAnswerIntent` files a MINIMAL report (no sensor capture) — logged
  deviation from the issue's "with sensor context".** Sensor capture needs
  async permission/background work that is out of budget for an out-of-process
  intent — the exact constraint `QuickAnswerFiler` documents. So intent-filed
  reports carry provenance (`DeviceIdentity`, stamped in `ReportBuilder`) but no
  live sensors, same as widget/notification quick answers. Full sensor context
  on intent-filed reports is deferred (it needs the foreground capture path);
  users who want sensors open the app via `FileReportIntent`. This preserves the
  report-centric invariant while being honest about what an out-of-process
  intent can do.
- **Question eligibility mirrors the quick-answer filer.** `LogAnswerIntent`
  targets any ENABLED question whose `reportKinds` include `.regular` (regular
  reports are the manual-entry surface); wake/sleep-only questions are not
  offered. `QuestionQuery.suggestedEntities` lists the same set so Shortcuts
  can't bind a value to an ineligible question.
- **Answer coercion is type-directed and lenient** (`coercedValue`): number →
  `.number` (raw string, `ReportBuilder` stores strings); yes/no → case-
  insensitive match to the two choices, else affirmative-word detection
  ("yes/y/true/1/on") → choice 0 else choice 1 (fallback literal "Yes"/"No" when
  the question has no choices); multiple-choice → case-insensitive match to a
  choice, else the raw string verbatim; tokens/people → comma-split, trimmed,
  empties dropped; note → verbatim; location → `.location(text:)`; time →
  `HH:mm`/`H:mm` parse to `TimeAnswer`, unparseable → `.skipped`. Empty raw →
  `.skipped`. Pure and unit-pinned.
- **Query intents are read-only and side-effect-free.** They open the shared
  store `allowsSave: false` and never touch CloudKit — safe to run from a
  background-launched Shortcuts process while the app has the store open (the
  `PromptGroupQuery` precedent). Count = `WidgetSnapshot.compute(...).todayCount`,
  streak = `ReportStreak.days(...)`, last answer = `AnswerSummary.lastAnswer`.
- **`FileReportIntent` supersedes `StartReportIntent`.** The type is renamed
  and gains the optional group parameter; nothing else referenced
  `StartReportIntent` (the Control Center action is the separate
  `StartReportControlIntent`, untouched). The group-scoped `SurveyRequest`
  reuses the plan-12 `promptGroupID` field already threaded through the survey.
- **`LogAnswerIntent` reuses the widget nag-cancel + webhook markers**
  (`WidgetQuickAnswerMarker.recordFiled`, `WebhookQueue.enqueue`) so an intent-
  filed report cancels its question's nag chain and delivers webhooks at the
  app's next foreground — identical to a widget quick answer. No new marker
  machinery.
- **Platform scope: iOS ships the full surface this plan; watchOS/macOS
  registration is a documented follow-up.** The kit backing is fully cross-
  platform and unit-tested, and the query intents need no `AppActions`, so the
  watch (own App Group store) and Mac (Application Support store) each need only
  a curated per-target `AppShortcutsProvider` + a store-URL resolver — deferred
  because each is an independent target build/verification and the issue itself
  gates a Mac *file-report* on capture-on-Mac (plan 36 v2). Logged here rather
  than silently dropped.
- **No schema change, no entitlement change, no build-number bump.**

## Observable Acceptance Criteria

The user-facing surface is the Shortcuts app / Siri / Spotlight, not an in-app
screen; criteria pin what is observable there and in the report history the
intents write to.

- In the Shortcuts app, the Dispatch app tile lists actions **File Report**,
  **Log Answer**, **Toggle Awake/Asleep**, **Today's Report Count**, **Current
  Streak**, and **Last Answer** (each intent's `title`).
- **File Report** shows an optional **Prompt Group** parameter; running it opens
  Dispatch to the survey (group-scoped when a group is chosen), same as tapping
  REPORT on Home — the new report appears in report history with a bolt/intent
  provenance (`trigger .intent`).
- **Log Answer** takes a **Question** parameter (populated from the user's
  enabled regular questions) and a **Value** text parameter; running it files a
  report WITHOUT opening the app and returns a dialog like *"Logged 2 to
  Coffees."*, and that one-answer report appears in report history.
- **Today's Report Count** returns a number and a dialog *"You've filed N
  reports today."*; **Current Streak** returns *"Your streak is N days."*;
  **Last Answer** (for a chosen question) returns the last answer text and its
  date, or *"No answer yet for <question>."* when none exists.
- Siri/Spotlight surface the donated phrases (e.g. "File a Dispatch report",
  "Log a Dispatch answer", "What's my Dispatch streak").

## Global Constraints

- Kit changes are test-first: failing `swift test` → implement → green, one
  scoped commit per task. The kit never imports `AppIntents`.
- The report-centric invariant holds everywhere: every answer-writing path goes
  through `ReportBuilder.save` inside a `Report`. No free-floating answer type.
- Frozen names later tasks depend on: `AnswerSummary.text(for:)`,
  `AnswerSummary.lastAnswer(toQuestionID:in:)`,
  `IntentAnswerFiler.coercedValue(forType:choices:raw:)`,
  `IntentAnswerFiler.eligibleQuestion(id:in:)`,
  `IntentAnswerFiler.file(questionID:raw:trigger:date:in:)`.
- App target verified with `xcodegen` + `xcodebuild build-for-testing`
  (iPhone 17 Pro simulator); the full UI/Shortcuts suite and on-device Siri
  verification are the merge gate (deferred — simulator-heavy). Do NOT touch
  signing/entitlements/branch-protection or the `mac-ui-smoke` workflow step.
- Do NOT merge the PR; it stays open for review.

---

### Task 1: Kit — `AnswerSummary` (flatten + last-answer query) (TDD)

**Files:**
- New: `Sources/DispatchKit/Intents/AnswerSummary.swift`
- New: `Tests/DispatchKitTests/AnswerSummaryTests.swift`

**Interfaces (produced):**
- `AnswerSummary.text(for response: Response) -> String?`
- `AnswerSummary.lastAnswer(toQuestionID id: String, in reports: [Report]) -> (text: String, date: Date)?`

- [x] Failing tests: `text(for:)` per type (tokens/people joined `, `; options
  joined; location text; time `HH:mm` / `(yesterday)`; numeric; note joined);
  payload-less response → nil. `lastAnswer`: picks the most recent non-draft
  report's answered response for the ID (drafts and payload-less responses
  skipped; ties by later `date`); nil when none.
- [x] Implement (pure, mirrors the exporter flatten precedence). `swift test` green.
- [x] Commit `feat(kit): AnswerSummary — response flatten + last-answer query (plan 43, #59)`.

### Task 2: Kit — `IntentAnswerFiler` (coercion + file) (TDD)

**Files:**
- New: `Sources/DispatchKit/Intents/IntentAnswerFiler.swift`
- New: `Tests/DispatchKitTests/IntentAnswerFilerTests.swift`

**Interfaces (produced):**
- `IntentAnswerFiler.coercedValue(forType:_ QuestionType, choices: [String], raw: String) -> AnswerValue`
- `IntentAnswerFiler.eligibleQuestion(id: String, in: ModelContext) -> Question?`
- `IntentAnswerFiler.file(questionID: String, raw: String, trigger: ReportTrigger, date: Date, in: ModelContext) throws -> Report?`

- [x] Failing tests: coercion per type (number/yesNo affirmative+choice-match/
  multipleChoice/tokens comma-split/note/location/time parse+fallback/empty→
  skipped); `eligibleQuestion` requires enabled + `.regular`; `file` creates ONE
  report with `trigger .intent` containing the coerced answer, and returns nil
  for a missing/ineligible ID.
- [x] Implement over `ReportBuilder.save`. `swift test` green.
- [x] Commit `feat(kit): IntentAnswerFiler — type-directed answer coercion + report filing (plan 43, #59)`.

### Task 3: App — `QuestionEntity` + query, and the six intents + donation

**Files:**
- New: `App/Sources/Intents/QuestionEntity.swift` (entity + read-only query)
- Modify: `App/Sources/Intents/DispatchIntents.swift` (rename `StartReportIntent`
  → `FileReportIntent` + group param; add `LogAnswerIntent`, the three query
  intents; extend `DispatchShortcuts`)
- Modify: `App/Sources/DispatchApp.swift` if the group-scoped survey needs a hook
  (reuse the existing `AppActions.surveyPresenter` path — no new hook expected)

- [x] `QuestionEntity`/`QuestionQuery` read the shared store read-only
  (`PromptGroupQuery` pattern); `suggestedEntities` = enabled `.regular`
  questions in sort order.
- [x] `FileReportIntent`: `openAppWhenRun`, optional `PromptGroupEntity` →
  `SurveyRequest(kind: .regular, trigger: .intent, promptGroupID:)`.
- [x] `LogAnswerIntent`: `QuestionEntity` + `@Parameter value: String`; opens the
  App Group store writable, `IntentAnswerFiler.file`, `WidgetQuickAnswerMarker
  .recordFiled`, `WebhookQueue.enqueue`, `WidgetCenter.reloadAllTimelines()`,
  returns `ProvidesDialog`. `isDiscoverable = true`.
- [x] Query intents `TodayReportCountIntent` / `CurrentStreakIntent` /
  `LastAnswerIntent`: read-only fetch → `WidgetSnapshot`/`ReportStreak`/
  `AnswerSummary`; `ReturnsValue<Int>`/`ReturnsValue<String>` + `ProvidesDialog`.
- [x] `DispatchShortcuts`: phrases for all discoverable intents.
- [x] `xcodegen` + `xcodebuild build-for-testing` (iPhone 17 Pro) green.
- [x] Commit `feat: first-class Shortcuts/App Intents — file report, log answer, queries (plan 43, #59)`.

### Task 4: Wrap + self-review

- [x] `swift test` green (note the count delta); iOS app builds.
- [x] Self-review: report-centric invariant (no answer written outside a
  `Report`); kit imports no `AppIntents`; query intents open the store read-only;
  `LogAnswerIntent` process contract matches `QuickAnswerIntent`.
- [x] Completion note: shipped, deviations (minimal-report sensor deferral),
  test counts, deferred watchOS/macOS registration.

---

## Completion note (2026-07-11)

_Filled in on completion below._
