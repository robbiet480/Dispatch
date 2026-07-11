# Dispatch Plan 47: Mac question/group management + catalog access

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (issues #57 + #58):** the Mac app is review-only today (plan 36 v1 scope
discipline). This is the v2 slice that turns the big-keyboard device into where
you do SETUP work: create/edit/reorder/enable/disable/delete questions,
manage prompt groups (membership, ordering, schedule kinds), move question
DEFINITIONS in and out as CSV/JSON, and reach the community question catalog
(browse, add, submit, flag). Issue #58's note — "probably one plan covering
both" — is honored: one plan, both surfaces, because "add from catalog" lands
in the same management shell as manual question creation.

**The hard correctness requirement (called out in issue #57):** editing a
prompt group or question on the Mac lands on the iPhone via CloudKit
mirroring. iOS must REPLAN notifications when those edits arrive REMOTELY —
otherwise a group edited on the Mac silently doesn't take effect until the
next app-open replan. This is the trickiest bit and is TDD'd kit-side (Task 2).

## Architecture

- **Kit-clean, testable core (the platform-neutral spine):**
  - `QuestionPortability` (new, `Sources/DispatchKit/Export/`): the CSV + JSON
    codecs and the import PLAN for question *definitions* (distinct from the
    existing report-DATA exporters). Pure value types + pure functions, no I/O,
    no SwiftData, no platform conditionals — `swift test` covers round-trip
    fidelity, per-row validation (reusing `CatalogValidation`), and dedupe
    (reusing `CatalogDedupe.normalizedPrompt`).
  - `RemoteChangeImpact` (new, `Sources/DispatchKit/Sync/`): a pure classifier
    that, given the set of changed model entity names in a remote-change
    batch, reports whether a notification replan / report reconciliation /
    vocabulary rebuild is warranted. The ONE tested definition of
    "a remote edit that must replan". Entity-name constants live on the models.
  - Shared display/config helpers move OUT of the iOS view files and INTO the
    kit so both the iOS and Mac editors use one definition:
    `QuestionType.displayName`, `ReportKind.displayName`,
    `NumberInputStyle.displayName` / `.exposedConfigFields` / `.parseConfigText`
    (issue #58 explicitly asks to reuse `exposedConfigFields`), and
    `GroupSchedule.summary`.
- **iOS replan wiring (behavior-preserving):** the iOS `RemoteChangeObserver`
  already calls `onRemoteChangesApplied` → `scheduler.replan(...)` on EVERY
  remote-change burst (verified: `DispatchApp.swift` L241–251). That coarse
  always-replan is a safe SUPERSET that already covers remote group/question
  edits. This plan makes the trigger EXPLICIT and tested: the observer computes
  the changed-entity set from persistent history and consults
  `RemoteChangeImpact`; the always-run fallback (nil/empty/error history ⇒ full
  pipeline) means behavior can only become more precise, never regress.
- **Mac UI (new `Mac/Sources/*` files, native SwiftUI):** a management surface
  reached from the detail-pane switcher and the menu bar:
  - `MacQuestionsView` — sortable list, per-row enable toggle, add/edit sheet
    (`MacQuestionEditorView`), delete-with-confirm, and toolbar entry points
    for CSV/JSON import (preview sheet) and export.
  - `MacPromptGroupsView` + `MacPromptGroupEditorView` — group CRUD,
    membership + ordering (selection-order = survey order), schedule-kind
    picker with the honest "fires on your iPhone" caveat for sensor kinds, and
    free-text calendar title matching (the Mac can't enumerate the phone's
    calendars — issue #57 note).
  - `MacCatalogView` (+ `MacCatalogSubmitView`) — browse/search the world-
    readable catalog, add-to-my-questions, submit, flag. `CatalogStore` /
    `CatalogProvider` gain dual target membership (both are already UIKit-free;
    `CatalogProvider` rides the CloudKit framework, available on macOS).
- **Import/export UI plumbing:** `MacExportController` gains question CSV/JSON
  save-panel exports and an open-panel import that runs `QuestionPortability`
  and presents a preview (`MacQuestionImportSheet`) listing adds/skips/errors
  before committing — the `--dry-run`-style sheet issue #57 asks for.

## Tech Stack

- DispatchKit (Foundation/SwiftData/SwiftUI-only), swift-testing (`import
  Testing`), SwiftUI + AppKit (NSSavePanel/NSOpenPanel) on macOS 26, CloudKit
  framework (catalog public DB), SwiftData + CloudKit mirroring
  (`NSPersistentStoreRemoteChange` / `NSPersistentHistoryTransaction`).

## Design decisions (decide + log)

- **DECISION 1 — question-definition JSON is a SUPERSET of the catalog seed
  shape, not identical to it.** Issue #57 asks that "JSON can mirror the catalog
  seed format so a curated seed file and a personal export are the same shape."
  The catalog seed (`CatalogSeedEntry`) carries prompt/type/choices/credit/tags
  + plan-41 input config. A personal question export additionally needs
  `enabled`, `sortOrder`, `reportKinds`, and `visualization` for exact round-
  trip. Chosen: `QuestionDefinition` JSON uses the SAME key names as the seed
  for the overlapping fields (so a seed file imports cleanly, extra fields
  defaulted) and ADDS the four personal fields. Rejected: reusing
  `CatalogSeedEntry` verbatim (loses enabled/order/kinds — fails the round-trip
  criterion) and a wholly separate shape (needless divergence from the seed).
- **DECISION 2 — CSV column schema is documented and choices/kinds are
  JSON-in-cell.** One header row, one question per row. Columns:
  `prompt,type,choices,reportKinds,enabled,sortOrder,placeholder,inputStyle,
  defaultAnswer,inputMin,inputMax,inputStep,visualization,stateOfMindKind`.
  `type` is the `QuestionType` case NAME (matching the seed's `type`);
  `choices` and `reportKinds` are JSON arrays inside the cell (round-trips
  through commas/quotes without a bespoke sub-delimiter); booleans are
  `true`/`false`; empty numeric cells mean nil. RFC-4180 quoting (double
  quotes doubled, fields with comma/quote/newline quoted). Rejected: a
  pipe/semicolon sub-delimiter for choices (breaks on user text containing it;
  JSON is already the catalog's choice-encoding via `CatalogChoicesJSON`).
- **DECISION 3 — import dedupe is by NORMALIZED prompt via `CatalogDedupe`,
  the same identity the catalog uses.** A row whose prompt normalizes to an
  existing question's prompt is a SKIP (not an error, not a duplicate insert);
  a row failing `CatalogValidation` is an ERROR (surfaced per-row); everything
  else is an ADD. The plan is computed PURELY and previewed before any write.
  Round-trip fidelity (export → wipe → import reproduces the list) is a kit
  test.
- **DECISION 4 — the replan classifier gates nothing away; it documents and
  refines.** `RemoteChangeImpact.classify(changedEntityNames:)` returns
  replan/reconcile/rebuild flags. `Question`, `PromptGroup`, and `Report`
  changes all warrant a replan (report arrivals feed nag reconciliation, which
  the replan then applies). The iOS observer consults it but keeps the
  always-full-pipeline fallback whenever the changed-entity set is unavailable,
  so the coarse-but-correct current behavior is the floor. Rejected: hard-
  gating the replan on entity type without a fallback (a history-parse miss
  would drop a needed replan — exactly the bug issue #57 warns about).
- **DECISION 5 — Mac management lives in the detail-pane switcher + a Manage
  menu, not a new window or a second sidebar.** The existing
  `MacDetailPane` segmented control (Dashboard/Insights) extends with
  Questions/Groups/Catalog; selecting a management pane clears any report
  selection so the detail pane isn't ambiguous. A `Manage` menu mirrors the
  panes with ⌘-number shortcuts. Rejected: separate windows (more scene
  plumbing than a v2 slice needs) and a sectioned sidebar (a larger
  `MacReportsListView` refactor that fights plan 36's reports-first sidebar).
- **DECISION 6 — the Mac group editor is honest about what it can't do.**
  Sensor schedule kinds (workout end, arrival, calendar-event end) are
  configurable but labeled "fires on your iPhone" — they execute on
  iOS/watch only. Calendar matching offers "all events" and free-text
  "title contains"; the "specific calendars" rule (which references the
  PHONE's `EKCalendar` identifiers the Mac can't enumerate — issue #57 note)
  is shown read-only when already set on a synced group and otherwise not
  offered. No schema change: the same `PromptGroup` fields the phone writes.
- **DECISION 7 — shared helpers move to the kit; iOS view files lose their
  private copies.** `displayName`/`exposedConfigFields`/etc. were internal
  extensions in `QuestionEditorView.swift` / `QuestionSettingsView.swift` /
  `PromptGroupsView.swift`. Duplicating them as Mac twins would drift; moving
  them to the kit (public) gives one definition both apps import. The iOS
  copies are DELETED to avoid same-module redeclaration. iOS is compile-checked
  with `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
  (compiles every app source without booting/contending for a simulator).

## Global Constraints

- Kit changes test-first: failing `swift test` → implement → green, per task.
- NO schema changes, NO new model fields, NO renumbering — the Mac reads/writes
  the exact store the phone/watch sync. CloudKit model rules already bind us.
- NEVER touch signing, entitlements, branch protection, or the mac-ui-smoke
  workflow step (owner-gated). Mac compile checks use `CODE_SIGNING_ALLOWED=NO`.
  No ASC/TestFlight/build-number bump.
- Simulator/Mac-UI RUNTIME verification is deferred (to avoid contending with
  other agents and per plan-36 precedent): verification here is `swift test`
  + `xcodebuild build` (Mac macOS + iOS generic) with signing disabled. The
  remote-edit replan RUNTIME smoke (edit on Mac, watch the phone replan) is an
  owner two-device step recorded in completion notes.
- Frozen accessibility identifiers listed in Observable Acceptance Criteria.
- Suites green before every commit; scoped commit per task on branch
  `plan-47-mac-management-catalog`. Don't commit HANDOFF.md.

## Observable Acceptance Criteria

- The detail-pane switcher (`detail-pane-picker`) shows **Dashboard ·
  Insights · Questions · Groups · Catalog**; picking **Questions** shows the
  question list (`mac-questions-list`) with an **Add Question** button
  (`mac-add-question`).
- In the questions list each row shows the prompt, its type + response count,
  and an enable toggle (`mac-question-enabled-<id>`); selecting a row opens the
  editor with a **Save** button (`mac-question-save`) disabled until the prompt
  is non-empty and at least one report kind is selected.
- The questions toolbar shows **Import…** (`mac-questions-import`) and an
  **Export** menu (`mac-questions-export`) offering CSV and JSON; importing a
  file first presents the preview sheet (`mac-question-import-sheet`) listing
  counts of **Add / Skip / Error** with an **Import N** confirm button
  (`mac-question-import-confirm`).
- Picking **Groups** shows the groups list (`mac-groups-list`) with **Add
  Group** (`mac-add-group`); the group editor's schedule picker
  (`mac-group-schedule-kind`) shows sensor kinds annotated "fires on your
  iPhone" (`mac-group-ios-only-note`) and offers calendar **All events** /
  **Title contains** only.
- Picking **Catalog** shows the catalog list (`mac-catalog-list`) with a search
  field and a **Submit** button (`mac-catalog-submit`); a catalog entry's
  detail has **Add to My Questions** (`mac-catalog-add`) and **Flag**
  (`mac-catalog-flag`).
- (Kit-observable, not screen) A remote-change batch whose changed entities
  include `PromptGroup` or `Question` classifies as replan-worthy
  (`RemoteChangeImpact`), and the iOS observer replans on it — the always-run
  fallback guarantees a replan even when the entity set is unknown.

---

### Task 1: Kit — shared display/config helpers move into DispatchKit (TDD)

- [ ] **Files:** create `Sources/DispatchKit/Models/QuestionDisplay.swift`
  (public `QuestionType.displayName`, `ReportKind.displayName`,
  `NumberInputStyle.displayName` / `.exposedConfigFields` / `.parseConfigText`,
  `GroupSchedule.summary`); edit `App/Sources/Settings/QuestionEditorView.swift`,
  `App/Sources/Settings/QuestionSettingsView.swift`,
  `App/Sources/Settings/PromptGroupsView.swift` to DELETE their now-duplicate
  private extensions; create `Tests/DispatchKitTests/QuestionDisplayTests.swift`.

Failing tests first: every `QuestionType`/`ReportKind`/`NumberInputStyle` case
has a non-empty display name; `exposedConfigFields` matches the plan-41 table
(textField none; slider/stepper/dial all three; tapCounter max-only; scale
min+max); `parseConfigText` rejects "", "inf", "nan", junk and accepts finite.

Verify: `swift test`. Commit `refactor(kit): share question display/config helpers (plan 47)`.

### Task 2: Kit — RemoteChangeImpact classifier (TDD)

- [ ] **Files:** create `Sources/DispatchKit/Sync/RemoteChangeImpact.swift`
  (entity-name constants + `classify(changedEntityNames:)`), create
  `Tests/DispatchKitTests/RemoteChangeImpactTests.swift`; edit
  `App/Sources/Sync/RemoteChangeObserver.swift` to compute the changed-entity
  set from persistent history and consult the classifier, with the
  full-pipeline fallback on nil/empty/error.

Failing tests first: `["PromptGroup"]` ⇒ replan; `["Question"]` ⇒ replan;
`["Report"]` ⇒ replan + reconcile; `["Vocabulary"]` ⇒ neither replan nor
reconcile (still rebuild? no — vocabulary is downstream, so `false`);
`[]` ⇒ the "unknown, do everything" sentinel returns all-true; unknown entity
name ⇒ conservative all-true.

**Contract:** pure, Sendable, no I/O. The observer's behavior is unchanged when
the entity set is unavailable. `swift test` green.

Verify: `swift test`. Commit `feat(kit): remote-change replan classifier + observer wiring (plan 47)`.

### Task 3: Kit — QuestionPortability CSV/JSON + import plan (TDD)

- [ ] **Files:** create `Sources/DispatchKit/Export/QuestionPortability.swift`,
  `Tests/DispatchKitTests/QuestionPortabilityTests.swift`.

Failing tests first: `QuestionDefinition` <-> `Question` bridge preserves every
field; JSON export→import round-trips a mixed question list EXACTLY (prompt,
type, choices, kinds, enabled, sortOrder, placeholder, input config,
visualization, stateOfMindKind); a catalog seed-shaped JSON imports (extra
personal fields defaulted); CSV export→import round-trips including prompts
containing commas/quotes/newlines and choices with commas; `QuestionImportPlan`
classifies adds/skips(dup by `CatalogDedupe.normalizedPrompt`)/errors(invalid
via `CatalogValidation`); deterministic ordering.

**Contract:** pure, no I/O, platform-neutral. `swift test` green.

Verify: `swift test`. Commit `feat(kit): question definition CSV/JSON portability (plan 47)`.

### Task 4: Mac — question management UI + import/export plumbing

- [ ] **Files:** create `Mac/Sources/MacQuestionsView.swift`,
  `Mac/Sources/MacQuestionEditorView.swift`,
  `Mac/Sources/MacQuestionImportSheet.swift`; edit
  `Mac/Sources/MacExportController.swift` (question CSV/JSON export via
  NSSavePanel; import via NSOpenPanel → `QuestionPortability` → preview);
  edit `Mac/Sources/MacRootView.swift` + `Mac/Sources/DispatchMacApp.swift`
  (extend `MacDetailPane`, add `Manage` menu). Add `CatalogStore.swift` +
  `CatalogProvider.swift` to the `DispatchMac` target sources in `project.yml`.

**Contract:** create/edit/reorder/enable/disable/delete questions against the
synced store; CSV+JSON export writes; import previews adds/skips/errors then
commits. `xcodegen generate` clean; Mac build (`CODE_SIGNING_ALLOWED=NO`) green;
iOS generic build green.

Verify: `swift test` + Mac build + iOS generic build. Commit `feat(mac): question management + CSV/JSON import/export (plan 47)`.

### Task 5: Mac — prompt group management

- [ ] **Files:** create `Mac/Sources/MacPromptGroupsView.swift`,
  `Mac/Sources/MacPromptGroupEditorView.swift`.

**Contract:** create/edit/enable/disable/delete groups; membership + ordering;
schedule kinds with the "fires on your iPhone" caveat; calendar all-events /
title-contains matching. No schema change; writes the same `PromptGroup` fields
the phone reads (so the phone replans on sync — Task 2).

Verify: `swift test` + Mac build. Commit `feat(mac): prompt group management (plan 47)`.

### Task 6: Mac — catalog access (browse, add, submit, flag)

- [ ] **Files:** create `Mac/Sources/MacCatalogView.swift`,
  `Mac/Sources/MacCatalogSubmitView.swift`.

**Contract:** browse/search catalog, add-to-my-questions, submit (throttle +
duplicate pre-check via the shared `CatalogStore`), flag. Reuses the shared
`exposedConfigFields` config-form logic (issue #58).

Verify: `swift test` + Mac build + iOS generic build. Commit `feat(mac): question catalog access (plan 47)`.

### Task 7: Wrap — README, plan completion notes, PR

- [ ] **Files:** edit `README.md` (Mac management/catalog + question
  import/export), this doc (completion notes). Rebase on main; open PR
  referencing #57 and #58; PR stays open for owner review (no merge).

Verify: `swift test`; Mac + iOS generic builds green. Commit `docs: plan 47 wrap + README (plan 47)`.
