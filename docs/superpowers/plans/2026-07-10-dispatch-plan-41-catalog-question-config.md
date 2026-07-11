# Dispatch Plan 41: Catalog question configuration — input style, default answer, placeholder

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issue:** #49 — *Catalog: support input style, default answer, and placeholder.*

**Goal:** catalog questions today carry only prompt / type / choices / credit / tags. Extend them to also carry **input style** (plan 21 number styles: slider/stepper/dial/tapCounter/scale/textField), **default answer**, and **placeholder**, so a submitted or curated question arrives *fully configured* — when a user taps "Add to my questions" the created local `Question` renders exactly the control the author intended, not a bare text field.

**Architecture:** additive and lenient everywhere, mirroring the plan-26/28 raw-leniency norm. Three new OPTIONAL fields ride the existing `SubmittedQuestion` and `CatalogQuestion` value types, their typed field dictionaries, the CloudKit record shapes, the seed-JSON entry, and the app's submit form. `CatalogValidation` gains structural bounds (input style meaningful only for `number`; length limits on default/placeholder). No field is ever required: an older seed, an older submitted record, and a pre-plan-41 catalog entry all decode with the three fields nil and behave exactly as today. The input-style bounds (`inputMin/inputMax/inputStep`) ride along as optional companions of `inputStyle` so an added question is byte-identical to one built in the editor — a style without its bounds is meaningless.

**Tech Stack:** DispatchKit pure value types + `[String: CatalogFieldValue]` dictionaries (CloudKit-free), `CatalogValidation` pure functions, CloudKit Web Services JSON (`dispatch-mod`) + `CKRecord` (app), `cktool`/Console schema deploy, SwiftUI submit form reusing the plan-21 editor controls, `QuestionAdmin.makeQuestion` local-question mapping.

## Design decisions (decide + log)

- **Three new fields, all optional, all lenient:** `inputStyle: String?` (the `NumberInputStyle` raw — `"slider"`, `"stepper"`, `"dial"`, `"tapCounter"`, `"scale"`; `nil` or an unknown raw ⇒ plain text field, matching `Question.inputStyle`'s own fallback), `defaultAnswer: String?`, `placeholder: String?`. Stored raw (never a throwing enum decode) so a future style name imports, persists, and re-exports untouched — the `ConnectionType`/`MediaSample` leniency precedent.
- **Input-style BOUNDS ride along (`inputMin/inputMax/inputStep: Double?`).** A style without its min/max/step renders on the survey via `NumberInputStyle.resolvedConfig`, which falls back to the style defaults — so bounds are optional *and* safe to omit. But an author who set a 1–5 scale wants 1–5, not the 0–10 default; carrying the three bounds makes "arrives fully configured" literally true and keeps the added question byte-identical to the editor's output. They are additive optional companions of `inputStyle`; when `inputStyle` is nil they are ignored (and should be omitted). **Decision: carry them.** They are cheap (three optional doubles) and the mapping to `Question` already exists field-for-field.
- **Input style is meaningful ONLY for `number`.** `CatalogValidation` rejects a non-nil `inputStyle` on any non-number type (`.inputStyleNotAllowed`) — the same shape as the existing `.choicesNotAllowed` gate. `defaultAnswer` is likewise number-only in the app editor (`QuestionEditorView.applyInputStyleFields` only writes it for `.number`), so validation rejects a non-nil `defaultAnswer` on a non-number type too (`.defaultAnswerNotAllowed`). **Placeholder is allowed for ANY type** — the editor's PLACEHOLDER section is unconditional (`QuestionEditorView` line ~242, no `type ==` gate), so the catalog matches: any question may carry a placeholder.
- **Unknown `inputStyle` raw is NOT a validation error.** Validation resolves the style leniently (`NumberInputStyle(rawValue:)` → nil ⇒ treated as textField) exactly like `Question.inputStyle`. An unknown style on a *number* question validates fine and simply renders as a text field on old builds — forward-lenient, no moderator action. Validation only rejects a style *present on a non-number type* (a structural category error), never an unrecognized string.
- **Length limits:** `defaultAnswerMaxLength = 40` (a number literal — the editor writes only decimal-parseable strings, but the wire tolerates anything; 40 is generous headroom), `placeholderMaxLength = 100` (a short hint, well under the 200-char prompt bound). Trimmed before the length check, symmetric with prompt/choice/credit. `.defaultAnswerTooLong(limit:)` / `.placeholderTooLong(limit:)`.
- **`normalized` extends to the new fields:** trims all three; empty collapses to nil (nothing to carry). Input-style bounds are not string values so they pass through untouched; `inputStyle`/`defaultAnswer`/`placeholder` follow the credit-name "empty ⇒ nil" rule.
- **CloudKit schema — additive scalar columns on BOTH record types.** `SubmittedQuestion` and `CatalogQuestion` each gain `inputStyle STRING`, `defaultAnswer STRING`, `placeholder STRING`, `inputMin DOUBLE`, `inputMax DOUBLE`, `inputStep DOUBLE`. All nullable, none indexed (never queried — the catalog sorts on `approvedAt` and filters client-side). Additive columns do not disturb existing records or the permission grants. **Development auto-creates these columns on the first write** carrying them (CloudKit dev schema is inferred from writes); **Production requires an OWNER Console/`cktool` deploy** — `cktool import-schema`/`validate-schema` are rejected in Production ("endpoint not applicable in the environment 'production'"), so promotion is **Console → Deploy Schema Changes → Production** (docs/moderation.md §3c). Ship order: land `schema.ckdb` + the code, run `dispatch-mod setup` against Development (or just let the first submit auto-create), then the OWNER deploys to Production before any Production write relies on the columns. Until Production is deployed, writes that OMIT the new fields keep working (they are nil-omitted) — only a write that SETS a new field before deploy would fail, so the OWNER-deploy step gates real use, not the merge.
- **Wire/field-dictionary shape:** the three strings map to `CatalogFieldValue.string`, the three bounds to a NEW `CatalogFieldValue.double` case (the field dictionary currently has string/int/date/stringList — doubles are new). `dispatch-mod`'s `fieldJSON`/`fieldValues` gain a `DOUBLE` arm; the app's `apply(fields:to:)`/`catalogQuestion(from:)` gain a `Double`/`Double?`(`as? Double`) arm. All emitted only when present (the existing `if let credit …` nil-omission pattern), so records without them stay byte-identical.
- **Seed JSON gains the fields, back-compatibly.** `CatalogSeedEntry` gains `inputStyle: String?`, `defaultAnswer: String?`, `placeholder: String?`, `inputMin/inputMax/inputStep: Double?`, all via `decodeIfPresent` (older seed files — the 100-question Tumblr seed — decode with them nil). `CatalogSeedDraft` carries them onto the `CatalogQuestion` it builds. `CatalogSeed.parse` runs the same `CatalogValidation` so a bad seed (input style on a yesNo entry) fails the file with a per-line message.
- **"Add to my questions" copies the fields onto the created `Question`.** `CatalogStore.addToMyQuestions` today calls `QuestionAdmin.makeQuestion(prompt:type:choices:placeholder:kinds:after:)` with `placeholder: nil`. Extend `makeQuestion` to accept the new optional fields (default nil so every existing caller compiles unchanged) and write them: `placeholderString`, `defaultAnswerString`, `inputStyleRaw`/`inputMin`/`inputMax`/`inputStep`. The `Question` model already has every one of these stored properties (plan 21) — zero local schema change, fresh UUID as today.
- **Submit form mirrors the editor, conditionally.** `CatalogSubmitView` gains an INPUT STYLE + DEFAULT ANSWER section shown only when `type == .number` (exactly the editor's `if type == .number` gate and `configFields` min/max/step exposure) and an unconditional PLACEHOLDER field. Reuse the plan-21 pieces where practical: the `NumberInputStyle.allCases` picker, the `configFields` exposure table, and `NumberInputStyle.displayName`. `CatalogStore.submit`'s signature grows the optional fields; it validates + normalizes them before writing.
- **Old app builds ignore what they don't understand.** A pre-plan-41 build reading a plan-41 catalog record simply never looks at the new `CKRecord` keys — `catalogQuestion(from:)` only extracts keys it knows — so the entry shows as before (bare style). Forward-lenient by omission; documented in docs/moderation.md.
- **No `QuestionType` change, no new entitlement, no schemaVersion bump.** This plan touches the catalog record shape only; the local `Question` model and the v2 export format already carry these fields (plan 21). Purely additive catalog surface.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate); `dispatch-mod` is macOS-only (`#if os(macOS)`), built with `swift build`.
- Additive + lenient only: every new field optional, omitted when nil/empty, decoded with `decodeIfPresent`/`as?`; unknown `inputStyle` raws resolve to textField (never a throwing decode); NEVER renumber `NumberInputStyle` raws or existing `CatalogValidationError` cases; NO schemaVersion bump.
- Schema discipline: `schema.ckdb` is the repo-canonical truth (pinned by `ModSchemaTests`). Development auto-creates additive columns on first write; **Production is an OWNER Console/`cktool` deploy** (docs/moderation.md §3c) — call it out in the completion note and DO NOT assume Production has the columns until the OWNER confirms the deploy.
- Reuse the question editor's own input-style/default/placeholder UI and the kit's `NumberInputStyle` config helpers for the submit form — no parallel second implementation of the style/bounds logic.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.

---

### Task 1: Kit — DTO fields, `CatalogFieldValue.double`, seed entry/draft

**Files:**
- Modify: `Sources/DispatchKit/Catalog/CatalogQuestion.swift` (`CatalogFieldValue`, `SubmittedQuestion`, `CatalogQuestion`, `approved(...)`), `Sources/DispatchKit/Catalog/CatalogSeed.swift` (`CatalogSeedEntry`, `CatalogSeedDraft`, `parse`)
- Test: extend `Tests/DispatchKitTests/CatalogTests.swift` (or the existing catalog value-type test file — grep for `SubmittedQuestion(` in `Tests/` and extend that file); add cases to whatever pins `CatalogSeed.parse`.

**Interfaces (produced — later tasks rely on these exact names):**
- `CatalogFieldValue.double(Double)` + `doubleValue: Double?`
- `SubmittedQuestion` / `CatalogQuestion` new stored props: `inputStyle: String?`, `defaultAnswer: String?`, `placeholder: String?`, `inputMin/inputMax/inputStep: Double?`; carried through both `.fields` and `init?(recordName:fields:)`
- `SubmittedQuestion.approved(recordName:approvedAt:tags:)` copies all six onto the `CatalogQuestion`
- `CatalogSeedEntry` + `CatalogSeedDraft` carry the six; `CatalogSeedDraft.catalogQuestion(...)` copies them

- [x] **Step 1: Write the failing tests.** (a) `CatalogFieldValue.double(2.5).doubleValue == 2.5`; other accessors return nil for it and it returns nil for `.doubleValue` on a `.string`. (b) Round-trip a `SubmittedQuestion(prompt:… inputStyle: "scale", defaultAnswer: "3", placeholder: "1–5", inputMin: 1, inputMax: 5, inputStep: 1)` through `.fields` → `init?(recordName:fields:)` and assert all six survive; a submission with all six nil produces a `.fields` dictionary containing NONE of the six keys (nil-omission) and re-inits equal. (c) Same round-trip for `CatalogQuestion`. (d) `submission.approved(recordName:approvedAt:tags:)` carries all six onto the catalog entry. (e) `CatalogSeed.parse` on a seed file whose number entry sets `"inputStyle": "slider", "inputMin": 0, "inputMax": 100, "defaultAnswer": "50", "placeholder": "0–100"` yields a draft carrying them; a seed file WITHOUT the keys parses with them nil (back-compat); the draft's `catalogQuestion(...)` carries them.
- [x] **Step 2: Run `swift test` — expect FAIL** (members don't exist).
- [x] **Step 3: Implement.** `CatalogFieldValue`: add `case double(Double)` and `public var doubleValue: Double?`. `SubmittedQuestion`/`CatalogQuestion`: add the six stored properties (defaulted-nil in `init` so callers compile), extend the computed `fields` with the `if let …, !isEmpty` (strings) / `if let …` (doubles) nil-omission pattern, and extend `init?(recordName:fields:)` to read them (`fields["inputStyle"]?.stringValue`, `fields["inputMin"]?.doubleValue`, …). `approved(...)` forwards all six. `CatalogSeedEntry`: add the six with `decodeIfPresent` in `init(from:)` and defaulted-nil in the memberwise `init`; update the doc-comment file-shape example. `CatalogSeedDraft`: add the six; `catalogQuestion(recordName:approvedAt:)` forwards them. `CatalogSeed.parse`: pass the entry's six into the new draft (after validation — Task 2 adds the validation arm; for now thread the values through).
- [x] **Step 4: Run `swift test` — expect PASS** (whole kit suite).
- [x] **Step 5: Commit** — `git commit -m "feat(kit): catalog DTOs + seed carry inputStyle/defaultAnswer/placeholder (+bounds)"` → push.

### Task 2: Kit — CatalogValidation for the new fields

**Files:**
- Modify: `Sources/DispatchKit/Catalog/CatalogValidation.swift` (new error cases, limits, `validate`, `normalized`), `Sources/DispatchKit/Catalog/CatalogSeed.swift` (`parse` passes the new fields into `validate`/`normalized`)
- Test: extend the catalog validation test file (grep `CatalogValidation.validate` in `Tests/`)

**Interfaces (produced):**
- `CatalogValidationError.inputStyleNotAllowed`, `.defaultAnswerNotAllowed`, `.defaultAnswerTooLong(limit: Int)`, `.placeholderTooLong(limit: Int)`
- `CatalogValidation.defaultAnswerMaxLength = 40`, `.placeholderMaxLength = 100`
- `validate(prompt:typeRaw:choices:creditName:inputStyle:defaultAnswer:placeholder:)` (new optional params, defaulted nil so existing callers compile)
- `normalized(prompt:choices:creditName:inputStyle:defaultAnswer:placeholder:)` returning the trimmed/empty-collapsed sextet

- [x] **Step 1: Write the failing tests.** (a) A number question with `inputStyle: "scale"`, `defaultAnswer: "3"`, `placeholder: "1–5"` returns no errors. (b) A `yesNo` question with `inputStyle: "slider"` returns `[.inputStyleNotAllowed]`; with `defaultAnswer: "3"` returns `[.defaultAnswerNotAllowed]`; with `placeholder: "hint"` returns NO error (placeholder allowed for any type). (c) An unknown style on a number question (`inputStyle: "hologram"`) returns NO error (leniency — resolves to textField). (d) `defaultAnswer` of 41 chars → `[.defaultAnswerTooLong(limit: 40)]`; `placeholder` of 101 chars → `[.placeholderTooLong(limit: 100)]`; both trimmed before counting. (e) Existing calls (no new args) behave identically — pin one pre-existing assertion untouched. (f) `normalized` trims and collapses empty → nil for all three strings. (g) `CatalogSeed.parse` fails a file whose `yesNo` entry carries `inputStyle` with a per-line `.inputStyleNotAllowed` message.
- [x] **Step 2: Run `swift test` — expect FAIL.**
- [x] **Step 3: Implement.** Add the four error cases + `message` arms (e.g. "Input style only applies to number questions.", "Default answers only apply to number questions.", "Default answer must be 40 characters or fewer.", "Placeholder must be 100 characters or fewer."). Add the two length constants. Extend `validate`: after the choices block, if `inputStyle != nil` (non-empty after trim) and `type != .number` append `.inputStyleNotAllowed`; if `defaultAnswer` non-empty and `type != .number` append `.defaultAnswerNotAllowed`; length-check trimmed `defaultAnswer`/`placeholder`. Do NOT reject unknown style strings. Extend `normalized` to trim + empty-collapse the three strings (bounds are numeric, not normalized here). `CatalogSeed.parse`: pass `entry.inputStyle`/`defaultAnswer`/`placeholder` into `validate`, and the normalized trio (plus the raw bounds) into the `CatalogSeedDraft`.
- [x] **Step 4: Run `swift test` — expect PASS.**
- [x] **Step 5: Commit** — `git commit -m "feat(kit): validate catalog input style / default answer / placeholder"` → push.

### Task 3: Schema — CloudKit columns + moderation docs

**Files:**
- Modify: `Sources/dispatch-mod/schema.ckdb` (both record types), `Tests/DispatchKitTests/ModSchemaTests.swift` (pin the new columns), `docs/moderation.md` (schema table + the Production-deploy call-out)

- [x] **Step 1: Write the failing schema test.** In `ModSchemaTests`, assert the whitespace-normalized `SubmittedQuestion` block and `CatalogQuestion` block each contain `inputStyle STRING`, `defaultAnswer STRING`, `placeholder STRING`, `inputMin DOUBLE`, `inputMax DOUBLE`, `inputStep DOUBLE` (use the existing `block(_:)` helper). Run — expect FAIL.
- [x] **Step 2: Edit `schema.ckdb`.** Add the six columns to BOTH `CatalogQuestion` and `SubmittedQuestion` record-type blocks, alphabetically placed among the existing fields, all nullable, none `SORTABLE`/`QUERYABLE` (never queried). Leave the `GRANT` lines untouched. (`DOUBLE` is CloudKit's type name for `Double`; verify against a `cktool export-schema` sample during implementation — if the tool emits a different spelling, match it and note it in the completion report.)
- [x] **Step 3: Docs.** In `docs/moderation.md`: extend the record-shape/schema documentation for `SubmittedQuestion` and `CatalogQuestion` with the six new fields (plan 41, optional, forward-lenient). Add an explicit line to the schema-deploy section: **these additive columns auto-create in Development on first write, but Production needs an OWNER Console deploy — Deploy Schema Changes → Production (§3c); `cktool import-schema`/`validate-schema` are rejected in Production. Writes that omit the new fields keep working before the deploy; only a write that SETS a new field before the Production deploy would fail.** Note that pre-plan-41 app builds ignore the new keys (forward-lenient).
- [x] **Step 4: Run `swift test` — expect PASS** (`ModSchemaTests` green; whole suite green). Optionally `xcrun cktool validate-schema` against Development if a management token is present (non-gating; note the result).
- [x] **Step 5: Commit** — `git commit -m "feat(schema): catalog config columns on SubmittedQuestion + CatalogQuestion"` → push.

### Task 4: dispatch-mod — DOUBLE field arm, approve/import carry-through

**Files:**
- Modify: `Sources/dispatch-mod/CloudKitWebClient.swift` (`fieldJSON`, `fieldValues` — add the `DOUBLE` arm), `Sources/dispatch-mod/DispatchMod.swift` (list/print sites if they enumerate fields — verify)
- Test: extend `Tests/DispatchKitTests/` mod-round-trip coverage if a `fieldJSON`/`fieldValues` test exists (grep `fieldJSON` in `Tests/`); otherwise add a focused test for the `.double` ↔ `DOUBLE` JSON round-trip.

**Interfaces (consumed):** Task 1's `CatalogFieldValue.double` and the DTO fields; Task 2's validation (already run inside `approve`).

- [x] **Step 1: Write/extend the test.** `CloudKitWebClient.fieldJSON([...: .double(2.5)])` emits `["value": 2.5, "type": "DOUBLE"]`; `fieldValues(["inputMin": ["value": 2.5, "type": "DOUBLE"]])` decodes `.double(2.5)`. A full `SubmittedQuestion` with all six fields → `fieldJSON(submission.fields)` → `fieldValues` → `SubmittedQuestion(recordName:fields:)` round-trips equal. (Guard with `#if os(macOS)` to match the target.)
- [x] **Step 2: Run — expect FAIL** (`DOUBLE` unhandled — currently falls through the `default` STRING arm).
- [x] **Step 3: Implement.** `fieldJSON`: add `case .double(let value): ["value": value, "type": "DOUBLE"]`. `fieldValues`: add `case "DOUBLE": if let d = entry["value"] as? Double { fields[name] = .double(d) }` (also tolerate `as? Int` promoted to Double — CKWS may serialize a whole number without a decimal). Because `approve()` copies `submission.approved(...)` → `catalog.fields`, and `createCatalogQuestions` writes `question.fields`, the new fields flow through BOTH the approve and import paths with no further change — the `.fields`/`init?` carry-through from Task 1 does the work. Verify `DispatchMod.swift`'s `list`/preview print sites don't need the new fields surfaced (they render `type`/`prompt` only — likely untouched; confirm and note).
- [x] **Step 4: Verify** — `swift test` (kit + mod round-trip), `swift build` (dispatch-mod compiles). Optional live smoke against Development: submit a configured number question from the app (Task 5) or hand-craft one, `dispatch-mod approve` it, confirm the catalog entry round-trips the fields via `dispatch-mod list`/a fetch.
- [x] **Step 5: Commit** — `git commit -m "feat(mod): DOUBLE field arm; approve/import carry catalog config fields"` → push.

### Task 5: App — submit form fields, store signature, add-to-my-questions mapping

**Files:**
- Modify: `App/Sources/Catalog/CatalogSubmitView.swift` (conditional INPUT STYLE + DEFAULT ANSWER sections, unconditional PLACEHOLDER, submit wiring), `App/Sources/Catalog/CatalogStore.swift` (`submit` signature + `addToMyQuestions` mapping), `App/Sources/Catalog/CatalogProvider.swift` (`CatalogProviding.submit` + `CloudKitCatalogProvider.submit` + `StubCatalogProvider.submit` signatures, `apply(fields:to:)`/`catalogQuestion(from:)` Double arm), `Sources/DispatchKit/UIState/QuestionAdmin.swift` (`makeQuestion` new optional params)
- Test: extend catalog UI tests (`AppUITests/` — grep `catalog-submit`); the `addToMyQuestions` mapping is coverable in a kit/app unit test via `QuestionAdmin.makeQuestion`.

**Interfaces (consumed):** Task 1 DTOs, Task 2 validation, Task 4 provider write path.

- [x] **Step 1: `QuestionAdmin.makeQuestion` gains optional params.** Add `defaultAnswer: String? = nil, inputStyle: String? = nil, inputMin: Double? = nil, inputMax: Double? = nil, inputStep: Double? = nil` (placeholder already a param). Write them onto the `Question` (`defaultAnswerString`, `inputStyleRaw`, `inputMin/Max/Step`). Defaults keep every existing caller compiling. Kit test: `makeQuestion(... inputStyle: "scale", inputMin: 1, inputMax: 5, defaultAnswer: "3", placeholder: "1–5")` produces a `Question` whose `inputStyle == .scale`, bounds set, `defaultAnswerString == "3"`, `placeholderString == "1–5"`.
- [x] **Step 2: `CatalogStore.addToMyQuestions` copies the fields.** Pass `entry.placeholder`, `entry.defaultAnswer`, `entry.inputStyle`, `entry.inputMin/Max/Step` into `makeQuestion`. The created local `Question` now renders the author's control. (Fresh UUID, dedupe on prompt+type unchanged.)
- [x] **Step 3: `CatalogStore.submit` + provider signatures.** `submit(prompt:typeRaw:choices:creditName:inputStyle:defaultAnswer:placeholder:inputMin:inputMax:inputStep:)` — validate via the extended `CatalogValidation.validate` (pass the new args), normalize the three strings, then call `provider.submit(...)` with the widened signature. Update `CatalogProviding.submit`, `CloudKitCatalogProvider.submit` (build the `SubmittedQuestion` with all six, `apply(fields:to:)` already writes via the dictionary once its Double arm exists), and `StubCatalogProvider.submit` (append to its recorded tuple — widen the tuple). Add the `.double`→`CKRecordValue` arm to `apply(fields:to:)` and a `record[key] as? Double` arm to `catalogQuestion(from:)` for `inputMin/Max/Step` (+ read `inputStyle`/`defaultAnswer`/`placeholder` strings).
- [x] **Step 4: Submit form UI (reuse the editor's shapes).** In `CatalogSubmitView`: add `@State` for `inputStyle: NumberInputStyle`, `inputMin/Max/Step: String`, `defaultAnswer: String`, `placeholder: String` (init from the passed pre-fill args — extend the `init` the editor calls so "Submit this question" from the editor carries its current config). Show an INPUT STYLE section and a DEFAULT ANSWER section ONLY `if type == .number` — copy the editor's `NumberInputStyle.allCases` picker, the `configFields` min/max/step exposure table, and identifiers (`input-style`, `input-min/max/step`, `default-answer-field`). Add an unconditional PLACEHOLDER `TextField`. On send, parse the bound strings to `Double?` (the editor's `parseConfig` discipline — nil for junk), gate default-answer/style to `.number`, and call the widened `store.submit(...)`.
- [x] **Step 5: UI test.** Under `--ui-testing`: open Submit, pick type Number, pick a scale style, set min/max, type a default and placeholder, Send; assert the `StubCatalogProvider` recorded the fields (or assert the confirmation screen — whichever the existing catalog UI test pattern uses). A second flow: a yesNo submission shows NO input-style/default sections but DOES show placeholder. Add-to-my-questions: tap a stub entry that carries a style, add it, open the question editor, assert the style/bounds/default/placeholder are populated.
- [x] **Step 6: Verify** — `swift test`, `xcodebuild build-for-testing`. Commit — `git commit -m "feat: catalog submit carries input style / default / placeholder; add-to-questions maps them"` → push.

### Task 6: Wrap + self-review

- [x] Full suites green (`swift test`, `swift build` for dispatch-mod, app `build-for-testing`; UI suite at the merge gate). Note the test-count delta.
- [x] Self-review the whole branch diff: (a) every new field optional + nil-omitted (prove a nil-everywhere submission/catalog record produces a field dictionary with NONE of the six keys); (b) unknown `inputStyle` raw never throws and never fails validation on a number question; (c) `inputStyle`/`defaultAnswer` rejected on non-number types, placeholder allowed on all; (d) `CatalogFieldValue.double`/`DOUBLE` round-trips through the app CKRecord bridge AND the mod CKWS JSON bridge; (e) older seed JSON (no new keys) still parses; (f) `QuestionAdmin.makeQuestion`'s new params defaulted so no existing caller broke; (g) `ModSchemaTests` pins the six columns on both types; (h) submit-form sections type-gated identically to the editor.
- [x] **Production schema reminder in the completion note (do NOT skip):** the six columns auto-create in Development on first write, but Production is an OWNER Console deploy (**Deploy Schema Changes → Production**, docs/moderation.md §3c). Flag it explicitly for Robbie — configured submissions cannot land in Production until he deploys. Until then, unconfigured submissions keep working.
- [x] Completion note in this doc (what shipped, divergences, the `DOUBLE` schema-spelling verification result, test counts, the pending OWNER Production deploy). Whole-branch review follows (controller-driven).

---

## Completion note (2026-07-10)

**Shipped** — all six tasks, one commit each on `plan-41-doc` (rebased onto
origin/main first, past the plan-28/37/40 merges and the TimeAnswer fix):

1. Kit DTOs + seed carry the six fields; `CatalogFieldValue.double`.
2. `CatalogValidation`: `.inputStyleNotAllowed` / `.defaultAnswerNotAllowed` /
   `.defaultAnswerTooLong(40)` / `.placeholderTooLong(100)`; `normalized`
   trims + empty-collapses the trio; seed parse validates per-line.
3. `schema.ckdb`: six nullable, unindexed columns on BOTH record types;
   `ModSchemaTests` pins them; docs/moderation.md documents shapes + deploy.
4. dispatch-mod: `DOUBLE` arm in `fieldValues` (write arm landed with task 1 —
   see divergences), approve validates the new fields, wire round-trip tests.
5. App: `QuestionAdmin.makeQuestion` optional params; add-to-my-questions
   copies the config; `CatalogStore.submit` + provider signatures widened;
   CKRecord bridge `.double` arms; submit form mirrors the editor via shared
   `NumberInputStyle.exposedConfigFields`/`parseConfigText`; editor sheet
   pre-fills its config; stub gains a configured scale entry; 3 new UI tests.

**Test counts:** DispatchKit swift-testing 540 → 556; XCTest suites
(ModConfig/ModSchema/ModFieldJSON) all green including 5 new wire round-trip
tests and 1 new schema-pin test. `swift build` (dispatch-mod), `xcodegen`,
`xcodebuild build-for-testing` (DispatchApp), and builds of DispatchWatch +
DispatchWidgets all pass. UI suite reserved for the merge gate as planned.

**Divergences from the plan doc:**
- Task 4 expected the `DOUBLE` write arm to be missing until task 4; in
  reality `fieldJSON`'s switch is exhaustive, so adding `.double` in task 1
  forced the write arm there. Task 4 added the read arm + tests.
- Task 4's round-trip tests pass `fieldJSON` output through
  `JSONSerialization` (bytes and back) — `fieldValues` consumes NSNumber
  values on the real wire, and Swift-native `Int` doesn't cast to `Double`
  the way NSNumber does. Truer to the wire than the plan's sketch.
- The plan's "reuse the editor's exposure table" is implemented by extracting
  the editor's private `configFields`/`parseConfig` into shared
  `NumberInputStyle.exposedConfigFields` / `parseConfigText` (app target);
  both views now call the same definitions.

**`DOUBLE` spelling verification:** `xcrun cktool validate-schema` against
the live **Development** environment accepts the updated `schema.ckdb`
("Schema is valid") — `DOUBLE` is the correct schema-language spelling.

**⚠️ Pending OWNER action — Production schema deploy:** the six columns
exist in Development (validated; they also auto-create on the first
configured write). **Production requires the Console deploy: CloudKit
Console → Schema → Deploy Schema Changes → Production** (docs/moderation.md
§3c; `cktool` cannot do this). Until deployed, configured submissions FAIL in
Production (TestFlight builds); unconfigured submissions keep working.
