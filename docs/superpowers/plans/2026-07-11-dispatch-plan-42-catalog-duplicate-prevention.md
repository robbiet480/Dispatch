# Dispatch Plan 42: Catalog duplicate-submission prevention

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issue:** #47 — *Catalog: prevent duplicate question submissions.*

**Goal:** nothing stops the same question prompt from entering the catalog pipeline repeatedly — one user resubmitting, or many users independently submitting a common question ("Did you exercise today?"). That floods the moderation queue and risks duplicate `CatalogQuestion` entries. This plan adds **content-identity dedupe**: a shared, deterministic prompt normalizer in DispatchKit, enforcement in `dispatch-mod` (the only writer of catalog entries), and pre-submit UX in the app ("this question is already in the catalog — add it instead?"). Distinct from plan 38 / issue #31, which caps *how many* submissions a user makes; this plan is about *identical content*. Both gate announcing open submissions.

**Tech Stack:** DispatchKit pure value logic (CryptoKit SHA-256 — already a kit dependency via `CKWebServicesSigner`), CloudKit Web Services JSON (`dispatch-mod`) + `CKRecord` (app), one additive QUERYABLE schema field, SwiftUI duplicate-resolution UX reusing the existing add-from-catalog path.

## Threat/limits model (log it, don't hand-wave)

- **CloudKit public DB cannot enforce field uniqueness server-side.** There is no unique constraint, no conditional create. So dedupe is layered: the client pre-check is *friction/UX* (trivially bypassable), and `dispatch-mod` is *enforcement* — nothing reaches the catalog without an approve/import, and those paths will refuse duplicates. A scripted client can still flood the *moderation queue* with identical submissions; plan 38's flood detection handles volume, and this plan's `list` duplicate markers make content floods visually collapse.
- **v1 duplicate identity = exact normalized-prompt match.** Deterministic and kit-testable: no ML, no fuzzy matching. Near-duplicates (edit distance, stemming — "Did you exercise?" vs "Did you exercise today?") are explicitly a follow-up; noted in docs, not built.

## Design decisions (decide + log)

- **One normalizer, in the kit, used by everything.** New `CatalogDedupe` (pure, `Sources/DispatchKit/Catalog/CatalogDedupe.swift`): `normalizedPrompt(_:)` applies, in order: Unicode NFC (`precomposedStringWithCanonicalMapping`), curly→straight quote/apostrophe folding (`’‘` → `'`, `“”` → `"`), locale-independent `lowercased()`, whitespace/newline runs collapsed to a single space, leading/trailing whitespace trimmed, and a trailing run of terminal punctuation (`.`, `?`, `!`, `…`, `‽`) stripped. So `"  Did you  exercise today?!"` ≡ `"did you exercise today"`. **No diacritic folding in v1** (café ≠ cafe) — conservative, deterministic; folding is part of the fuzzy follow-up.
- **Fingerprint = lowercase-hex SHA-256 of the UTF-8 normalized prompt** (`CatalogDedupe.promptFingerprint(_:)`). Stable across platforms/OS versions because the normalizer avoids locale-sensitive APIs. A test pins an exact hex vector so any accidental normalizer change screams.
- **Duplicate identity is prompt-only, ignoring type/choices** — matching the existing seed-import precedent (`prompt.lowercased()` skip) and the seed-file in-file duplicate check. Same prompt with a different type is still a moderation collision; the moderator decides (see `--allow-duplicate`).
- **Schema: ONE additive field — `CatalogQuestion.promptFingerprint STRING QUERYABLE`.** Written only by `dispatch-mod` (sole writer of the record type), so it's trustworthy. Enables the client's cheap targeted pre-check (`promptFingerprint == <hash>`, resultsLimit 1) without loading the whole catalog and without a SEARCHABLE index on `prompt`. `SubmittedQuestion` gains **no** field: the mod tool recomputes fingerprints from prompts at read time (client-supplied fingerprints would be untrusted anyway).
- **Old catalog records lack the field — backfill + fallback.** New `dispatch-mod backfill-fingerprints`: fetches all catalog entries, `forceUpdate`s the ones missing `promptFingerprint`, per-record verified (the plan-20 lesson: `records/modify` reports failures inside HTTP 200). Until run, mod-side dedupe is unaffected (it compares normalized prompts computed from fetched records, never stored fingerprints) and the client pre-check simply misses un-backfilled entries — acceptable, because the client check is UX-only and it *also* scans the already-loaded entries by normalized prompt.
- **Enforcement point 1 — `approve` refuses duplicates.** Before creating the `CatalogQuestion`, fetch catalog entries and compare normalized prompts; on a match, fail with the existing entry's recordName and prompt. `--allow-duplicate` overrides (moderator judgment — e.g. same prompt, deliberately different type). Approve also writes `promptFingerprint` on the created record (via `CatalogQuestion.fields`).
- **Enforcement point 2 — `import` uses the shared normalizer.** The existing skip (`prompt.lowercased()`) upgrades to `CatalogDedupe.normalizedPrompt`, both against the live catalog and (in `CatalogSeed.parse`) within the seed file. Imported records carry `promptFingerprint`.
- **Visibility — `list` flags duplicates.** Each pending submission is marked `⚠️ DUPLICATE of <catalogRecordName>` when its normalized prompt matches a catalog entry, or `⚠️ DUPLICATE of pending <recordName>` when it matches an *earlier* pending submission (first occurrence unmarked). The dashboard pending rows get the same badge (record names/prompts stay HTML-escaped as today).
- **Client pre-check — block exact matches with "add it instead", never a soft warn.** In `CatalogStore.submit`, before `provider.submit`: (1) scan the already-loaded `entries` by normalized prompt; (2) targeted provider query `catalogQuestion(fingerprint:)`. On a hit, throw a new `CatalogProviderError.duplicate(existing: CatalogQuestion)`. `CatalogSubmitView` catches it and renders a dedicated section: the existing entry + an **Add to My Questions** button (the existing `addToMyQuestions` path — fresh UUID, prompt+type no-op dedupe) + keep-editing affordance (the user can reword the prompt and resubmit). Exact-normalized match to a published entry has no legitimate "submit anyway" case, so no bypass button — rewording IS the bypass, and moderation still backstops.
- **Client resubmit guard — the user's own recent submissions.** Successful submissions record their fingerprint in `UserDefaults.standard` under `catalog.submittedFingerprints` (capped at the most recent 50). A repeat submit of the same normalized prompt throws `CatalogProviderError.alreadySubmitted` → "You already submitted this question. It's waiting for moderation." Per-device by design (same honesty as plan 38's throttle: friction, not security). Distinct key from plan 38's `catalog.submissionTimestamps`.
- **Pre-check failures never block submission.** If the fingerprint query errors (offline, index not yet deployed, record type missing), treat as "no duplicate found" and proceed — the check is UX; `dispatch-mod` enforces. Reuses the provider's existing `isMissingRecordType` tolerance.
- **CloudKit schema discipline (the part auto-create does NOT cover):** the *field* auto-creates in Development on first write, but the **QUERYABLE index does not**. Development deploy = the export→merge→validate→import flow (`cktool export-schema` fresh from live Dev → merge the one field line → `validate-schema` → `import-schema`; import REPLACES the environment schema, so always merge into a fresh live export, never import a stale file). `schema.ckdb` in-repo is updated in the same change and pinned by `ModSchemaTests`. **Production is an OWNER Console deploy** (Console → Schema → Deploy Schema Changes → Production, docs/moderation.md §3c) — flagged for Robbie in the completion note; until deployed, Production clients' fingerprint query fails harmlessly (treated as no-dup) and approves from dev tooling against Production would fail on the unknown field only if they SET it — so hold Production approves until the deploy, or deploy first.
- **Coexistence with plan 38 (being implemented concurrently, PR #32):** both touch `CatalogStore.submit`, `CatalogProviderError`, `CatalogSubmitView`, `DispatchMod.swift`'s `list`, the dashboard, and docs/moderation.md. This plan keeps every edit additive and section-scoped: a NEW error case (not touching theirs), a NEW UserDefaults key, a NEW submit-view section, NEW list annotation lines. Order of checks in `submit` once both land: validation → duplicate pre-check → throttle → provider write, so a blocked duplicate never burns a plan-38 quota slot. Flag any collision in the PR rather than restructuring their code.
- **No new record types, no entitlement changes, no build-number bump. The app still never writes `CatalogQuestion`.**

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → green, per task. App target verified with `xcodegen` + `xcodebuild build-for-testing` (iPhone 17 Pro simulator); full UI suite reserved for the merge gate. `dispatch-mod` is macOS-only (`#if os(macOS)`), built with `swift build`.
- `records/modify` returns per-record errors inside HTTP 200 — every new write path verifies via `verifyModifyResponse` (backfill included).
- `schema.ckdb` stays repo-canonical (pinned by `ModSchemaTests`); live Development import via export→merge→validate→import only.
- One scoped commit per task; suites green before every commit. Do NOT merge the PR; Production schema deploy is the OWNER's.

---

### Task 1: Kit — `CatalogDedupe` normalizer + fingerprint (TDD)

**Files:**
- New: `Sources/DispatchKit/Catalog/CatalogDedupe.swift`
- New: `Tests/DispatchKitTests/CatalogDedupeTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `CatalogDedupe.normalizedPrompt(_ prompt: String) -> String`
- `CatalogDedupe.promptFingerprint(_ prompt: String) -> String` (lowercase hex SHA-256 of the normalized prompt's UTF-8)
- `CatalogDedupe.isDuplicate(_ a: String, _ b: String) -> Bool`
- `CatalogDedupe.firstMatch(prompt: String, in entries: [CatalogQuestion]) -> CatalogQuestion?`

- [ ] **Step 1: failing tests.** Normalization: case fold, internal whitespace/newline collapse, trim, trailing `.?!…‽` run stripped (but internal punctuation kept: `"Coffee? Tea?"` keeps the first `?`), curly quotes/apostrophes folded (`"Who’d you meet?"` ≡ `"who'd you meet"`), NFC (composed vs decomposed `é` equal), no diacritic folding (`"café"` ≠ `"cafe"`), empty/whitespace-only → empty string. Fingerprint: pinned hex vector for a known input; equal for normalization-equivalent inputs; different for different prompts. `firstMatch` finds a stub entry by messy prompt; nil when absent.
- [ ] **Step 2: `swift test` — expect FAIL.** Implement (pure functions, CryptoKit). **Step 3: `swift test` — PASS.**
- [ ] **Step 4: commit** `feat(kit): CatalogDedupe — normalized-prompt identity + SHA-256 fingerprint (plan 42, #47)`.

### Task 2: Kit — seed import dedupe uses the shared normalizer

**Files:**
- Modify: `Sources/DispatchKit/Catalog/CatalogSeed.swift` (`parse`'s in-file `seenPrompts` keys on `CatalogDedupe.normalizedPrompt`)
- Test: extend `Tests/DispatchKitTests/CatalogSeedTests.swift`

- [ ] Failing test: a seed file containing `"Did you exercise today?"` and `"did you   exercise today"` fails with a per-line duplicate-prompt problem (today's `.lowercased()` check misses it). Implement, `swift test` green.
- [ ] Commit `feat(kit): seed-file duplicate check uses CatalogDedupe normalization (plan 42, #47)`.

### Task 3: Schema — `promptFingerprint STRING QUERYABLE` + docs + Development import

**Files:**
- Modify: `Sources/dispatch-mod/schema.ckdb` (CatalogQuestion block only), `Tests/DispatchKitTests/ModSchemaTests.swift` (pin), `docs/moderation.md` (record shape, dedupe section, Production deploy call-out)

- [ ] Failing `ModSchemaTests` assertion: CatalogQuestion block contains `promptFingerprint STRING QUERYABLE`; SubmittedQuestion block does NOT contain `promptFingerprint`. Edit `schema.ckdb` (alphabetical placement, grants untouched). Test green.
- [ ] Docs: document the field (mod-tool-written, backfillable, client uses it for the pre-check query), the duplicate workflow (`list` markers → `approve` refusal → `--allow-duplicate`), `backfill-fingerprints`, and the deploy reality: **field auto-creates in Dev on write, the QUERYABLE index does not — run the export→merge→validate→import flow for Development; Production = OWNER Console deploy (§3c).**
- [ ] Development deploy (live, team UTQFCBPQRF, container iCloud.io.robbie.Dispatch): `cktool export-schema` fresh from Dev → merge the field line → `validate-schema` → `import-schema`. Record the result in the completion note (skip gracefully if no management token available; note it).
- [ ] Commit `feat(schema): CatalogQuestion.promptFingerprint (QUERYABLE) + dedupe docs (plan 42, #47)`.

### Task 4: dispatch-mod — approve refusal, import fingerprints, list markers, backfill, dashboard badge

**Files:**
- Modify: `Sources/DispatchKit/Catalog/CatalogQuestion.swift` (`CatalogQuestion.promptFingerprint: String?` stored prop, carried via `fields`/`init?(recordName:fields:)`, nil-omitted; `approved(...)` computes it via `CatalogDedupe`), `Sources/dispatch-mod/CloudKitWebClient.swift` (`approve` dup check + `allowDuplicate:` param; `catalogQuestions()` reuse; `backfillFingerprints()` with forceUpdate + per-record verify), `Sources/dispatch-mod/DispatchMod.swift` (`--allow-duplicate` flag, `backfill-fingerprints` subcommand, `list` duplicate markers, help text), `Sources/dispatch-mod/Dashboard.swift` (duplicate badge on pending rows), `Sources/dispatch-mod/CloudKitWebClient+Import.swift` / import path (normalizer skip; fingerprint rides `fields` automatically)
- Test: extend `Tests/DispatchKitTests/CatalogTests.swift` (fingerprint round-trips `fields` ↔ `init?`; nil-omission; `approved(...)` sets it) — mod-side network paths stay live-verified, not unit-mocked (existing convention)

- [ ] Kit failing tests first: `CatalogQuestion` carries `promptFingerprint` through the field dictionary (present when set, absent when nil); `submission.approved(...)` returns an entry whose fingerprint equals `CatalogDedupe.promptFingerprint(prompt)`. Green, then the mod-tool wiring.
- [ ] `approve`: fetch catalog entries, `CatalogDedupe.firstMatch` on the submission's prompt (computed from fetched prompts, never stored fingerprints); refuse with recordName + prompt of the existing entry unless `--allow-duplicate`. `import`: skip-set keys on `normalizedPrompt`. `list`: catalog-dup and pending-dup markers. `backfill-fingerprints`: forceUpdate only records missing the field, per-record verified, prints count. Dashboard: escaped badge.
- [ ] Verify: `swift test`, `swift build`, `swift run dispatch-mod --help`. Optional live Dev smoke: submit a dup of a catalog prompt, see the `list` marker, watch `approve` refuse, `--allow-duplicate` succeed, `backfill-fingerprints` no-op afterwards.
- [ ] Commit `feat(mod): duplicate-aware approve/list/import + fingerprint backfill (plan 42, #47)`.

### Task 5: App — provider fingerprint lookup, store pre-check, resubmit guard, submit-view UX

**Files:**
- Modify: `App/Sources/Catalog/CatalogProvider.swift` (`CatalogProviderError.duplicate(existing:)` + `.alreadySubmitted`; protocol + CloudKit + stub `catalogQuestion(fingerprint:) async -> CatalogQuestion?`; `catalogQuestion(from:)` reads `promptFingerprint`), `App/Sources/Catalog/CatalogStore.swift` (pre-check order: validate → loaded-entries scan → fingerprint query → own-fingerprint guard → provider.submit; record fingerprint on success), `App/Sources/Catalog/CatalogSubmitView.swift` (duplicate section: existing entry + Add to My Questions via `store.addToMyQuestions` + modelContext, and the already-submitted message), UI test in the catalog suite
- Note: `catalogQuestion(fingerprint:)` returns nil on ANY error (missing index/record type/offline) — UX-only check, never blocks submission.

- [ ] Stub provider resolves fingerprints against `stubEntries` (computed via `CatalogDedupe`), so the UI test drives the whole flow: submit `"did you DRINK water today?!"` → duplicate section appears naming "Did you drink water today?" → Add to My Questions → confirmation; second flow: a fresh prompt submits, resubmitting the same prompt shows the already-submitted message. Existing `catalog-submit-*` identifiers unchanged; new ones `catalog-submit-duplicate`, `catalog-submit-duplicate-add`.
- [ ] Verify: `swift test`, `xcodegen`, `xcodebuild build-for-testing` (iPhone 17 Pro sim), the new UI test(s) if runnable in isolation.
- [ ] Commit `feat: catalog submit pre-checks duplicates — add-instead UX + resubmit guard (plan 42, #47)`.

### Task 6: Wrap + self-review

- [ ] Full suites green (`swift test`, `swift build` dispatch-mod, app `build-for-testing`); note the test-count delta.
- [ ] Self-review the branch diff: (a) normalizer used by seed parse, import skip, approve check, list markers, store pre-check — no second normalization implementation anywhere; (b) `promptFingerprint` nil-omitted, absent on SubmittedQuestion, pinned in `ModSchemaTests`; (c) pre-check failure paths all fall through to submit; (d) every new `records/modify` write verified per-record; (e) plan-38 collision surface (submit/store/view/list/dashboard/docs) kept additive.
- [ ] **Production reminder for the completion note (do NOT skip):** OWNER must Console-deploy `CatalogQuestion.promptFingerprint` (String + QUERYABLE index) to Production before running `backfill-fingerprints`/duplicate-writing approves against Production; client pre-check silently no-ops until then.
- [ ] Completion note in this doc: shipped/divergences/test counts/live-verification results/pending OWNER deploy.
