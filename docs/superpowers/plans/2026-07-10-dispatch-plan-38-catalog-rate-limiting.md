# Dispatch Plan 38: Catalog submission rate limiting

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** abuse protection for community question submissions — the recorded precondition (issue #31, carried from #8) gating ANY public announcement of open submissions. CloudKit's public database has **no server-side rate limiting for authenticated creates**, so this plan is layered mitigation, described honestly: (1) a client-side per-device submission throttle (friction, not security), (2) moderation-side flood detection + one-command bulk cleanup in `dispatch-mod` (the real defense — nothing reaches the catalog without approval), and (3) a documented emergency lever that turns submissions off globally from the Console. Catalog browsing and seeded content are already live and safe; this gates only the open-submissions announcement. Tracks GitHub issue #31 — reference it in commits/PRs.

**Scope discipline (hard constraints):** no new record types, no schema changes (the one index this plan relies on already exists), no entitlement changes, no server components. Flag (`QuestionFlag`) flooding is lower-stakes (flags are moderator-only inputs, never public) and is out of scope beyond the note in Task 3; if it ever matters, `QuestionFlag` already carries the same queryable `___createdBy` index.

## Threat model (log it, don't hand-wave)

- **What CloudKit gives us:** `SubmittedQuestion` is `_icloud` CREATE + creator-scoped read/write (docs/moderation.md §3a) — every submission is tied to a real, authenticated iCloud account via CloudKit's own creator metadata (`createdUserRecordName`), which we never store ourselves but can read at moderation time. `CatalogQuestion` is server-key-only by construction. So spam can flood the **moderation queue**, never the **catalog**.
- **What CloudKit does NOT give us:** any per-user create quota on the public DB. Any authenticated device can script unlimited `SubmittedQuestion` creates against the container. No client-side measure changes that.
- **Consequence:** the client throttle is UX friction that keeps honest users from accidental double-submits and makes casual abuse boring. The moderation tooling is the actual mitigation: detect floods by creator, reject them in one command. The Console lever is the circuit breaker when a flood is active and sustained.

## Design decisions (decide + log)

- **Layer 1 — client throttle is per-device, honest about being bypassable.** `SubmissionThrottle` lands in the kit as a pure, tested value type: rolling 24-hour window, **5 submissions per device per day** (generous for humans, irrelevant to scripts). Timestamps persist in `UserDefaults.standard` (per-device by design — NOT iCloud KVS: syncing the counter would punish multi-device users for a control that provides zero security anyway). The code comment and this doc both state plainly: this is trivially bypassable friction, not security. Recording happens only on **successful** submit — a validation or network failure never burns a slot.
- **Layer 2 — flood detection groups by CloudKit's creator metadata, client-side in the tool.** CloudKit Web Services query responses return `created.userRecordName` per record (the same metadata `whoami` already reads from a create response — `Sources/dispatch-mod/CloudKitWebClient.swift`). `queryRecords` currently discards it; it will surface it, and `SubmittedQuestion` (kit) gains an optional `createdUserRecordName` populated only by the mod tool's queries (the app never sees or stores user identifiers — the privacy posture from plan 20 is unchanged). Grouping/thresholding happens over the already-fetched full pending list — no server-side filter needed, so no new query shapes and no new index requirements.
- **Layer 2a — the index this relies on already exists; verify, don't add.** Creator-scoped read permissions make CloudKit inject an implicit creator filter into `SubmittedQuestion` queries, which is exactly why `schema.ckdb` already carries `"___createdBy" REFERENCE QUERYABLE` on `SubmittedQuestion` (and `QuestionFlag`) — the naming trap is documented in docs/moderation.md §3b (Console UI: `createdUserRecordName`, server errors: `createdBy`, schema language: `___createdBy`). Task 3 verifies this against live Development (`ModSchemaTests` already pins the schema file); nothing to create.
- **Flood threshold: >10 pending submissions from one creator = flagged loudly.** Twice the daily client cap, so a legitimate user who reinstalled or has multiple devices doesn't get flagged; a script does immediately. Threshold is a constant in the tool (`--flood-threshold N` override), not config-file surface area.
- **Bulk cleanup = `reject-user <userRecordName>`, destructive, so it confirms.** Prints the full list of that creator's pending submissions, requires interactive `y` (or `--yes` for scripting), then deletes them one by one with per-record verified results (the plan-20 lesson: never trust an unverified batch success). It only ever touches `SubmittedQuestion` — approved catalog entries are untouchable by definition of the moderation boundary.
- **Layer 3 — the emergency lever is a Console permission edit, documented, not built.** Revoking the `_icloud` CREATE grant on `SubmittedQuestion` (Console → Schema → record type → Security, per environment) turns off submissions **globally and immediately**: the app's submit path starts failing with a CloudKit permission error, which the existing `CatalogSubmitView` error path already renders. Catalog browsing is unaffected (`CatalogQuestion` keeps World read). Restoring is re-granting CREATE. One repo-side caveat must be documented: `schema.ckdb` is the canonical schema and `dispatch-mod setup` **imports it wholesale** — while the lever is engaged, do not run `setup` (it would re-grant CREATE from the file); the doc says so explicitly rather than adding a flag nobody will remember.
- **Submit UI shows remaining quota only when it bites.** A footer line ("N submissions left today" / "Daily limit reached — try again after <time>") appears in `CatalogSubmitView`; Send disables at zero with the reset time shown. No quota UI anywhere else — the catalog browse experience is untouched.

## Global Constraints

- Suites green before every commit: `swift test` + `xcodebuild build-for-testing` (iPhone simulator destination) per task; UI suite in the wrap task. Kit logic lands TDD-first (superpowers:test-driven-development).
- Branch workflow: worktree branch `plan-38-catalog-rate-limiting`, scoped commit per task, rebase on main before the PR. PR at the end titled `feat: catalog submission rate limiting (plan 38)`, body references #31.
- No schema changes, no new entitlements, no new record types or fields. Do NOT bump the build number. The app must never read, store, or display `createdUserRecordName` — creator identity is moderation-side only.
- `dispatch-mod` live verification runs against **Development** only; Production is untouched by this plan.

---

### Task 1: Kit — `SubmissionThrottle` (pure, TDD)

- [ ] **Files:** new `Sources/DispatchKit/Catalog/SubmissionThrottle.swift`, new `Tests/DispatchKitTests/SubmissionThrottleTests.swift`.

**Contract:** pure value logic, injected clock (`now:` parameters, no `Date()` inside): `remaining(now:)` from a stored `[Date]`, `canSubmit(now:)`, `recording(now:)` returns the pruned+appended array, `nextAllowed(now:)` for the reset-time UI. Limit 5 per rolling 24h, constant `SubmissionThrottle.dailyLimit`. Doc comment states verbatim that this is per-device friction, trivially bypassable, and that moderation (dispatch-mod flood detection) is the actual abuse control. Tests: empty history, boundary at exactly 24h, pruning of stale entries, ordering-insensitive input, `nextAllowed` correctness.

Verify: `swift test`. Commit `feat(kit): SubmissionThrottle — per-device catalog submission cap (plan 38, #31)`.

### Task 2: App — throttle wired into submit flow

- [ ] **Files:** `App/Sources/Catalog/CatalogStore.swift` (persist/prune timestamps in `UserDefaults.standard` under `catalog.submissionTimestamps`; expose `submissionsRemaining` / `nextSubmissionAllowed`; record a timestamp only after `provider.submit` returns without throwing; throw a new `CatalogProviderError.throttled(until:)` when exhausted so scripted paths hit the same wall as the UI), `App/Sources/Catalog/CatalogSubmitView.swift` (quota footer + Send disabled at zero with reset time; identifier `catalog-submit-quota`), UI test in the existing catalog suite (stub provider: submit up to the limit via seeded defaults, assert Send disabled + quota text — seed the timestamps through a launch-argument hook rather than five round-trips).

**Contract:** first submit of a fresh install shows no quota UI (footer appears only at ≤2 remaining or when exhausted — friction shouldn't advertise itself); failed submits don't consume quota; existing `catalog-submit-*` identifiers unchanged. Stub provider stays the UI-test boundary — no real CloudKit.

Verify: `swift test`, build-for-testing, catalog UI tests. Commit `feat: per-device submission throttle in catalog submit (plan 38, #31)`.

### Task 3: dispatch-mod — flood detection + `reject-user`

- [ ] **Files:** `Sources/dispatch-mod/CloudKitWebClient.swift` (`queryRecords` surfaces `created.userRecordName` from each raw record; `pendingSubmissions()` passes it through), `Sources/DispatchKit/Catalog/CatalogQuestion.swift` (`SubmittedQuestion.createdUserRecordName: String?`, nil outside the mod tool; kit tests updated), `Sources/dispatch-mod/DispatchMod.swift` (`list` gains a per-creator summary block — `Submitters: <user> ×N` — with a `⚠️ FLOOD` marker above the threshold, default 10, `--flood-threshold N`; new `reject-user <userRecordName>` subcommand: prints that creator's pending submissions, confirms interactively or via `--yes`, deletes with per-record verification, reports count; help text updated), `Sources/dispatch-mod/Dashboard.swift` (pending list groups by submitter with counts; flood marker; per-user bulk-reject button wired to a new `/api/reject-user` endpoint carrying the session token, same hardening rules — user record names are untrusted output, escape them).

**Contract:** grouping is client-side over the full pending fetch (no new query shapes). Verify against live Development: `list` shows the submitter summary; a `reject-user` round-trip on probe submissions (create a few via `whoami`-style probes or a dev build, bulk-reject, confirm `list` empties — noting query-index lag per docs/moderation.md). Confirm the `___createdBy QUERYABLE` index is present in the live schema (`setup --export` diff or the existing probes) — expected present since the plan-20 bootstrap; this task verifies, adds nothing.

Verify: `swift test`, `swift build`, `swift run dispatch-mod --help`, live Development smoke above. Commit `feat: dispatch-mod flood detection + reject-user bulk cleanup (plan 38, #31)`.

### Task 4: docs — emergency lever + operations; wrap

- [ ] **Files:** `docs/moderation.md` (new section "Abuse response & the emergency lever": the three layers and what each honestly provides; flood-detection workflow — `list` → `reject-user`; the Console circuit breaker: revoke `_icloud` CREATE on `SubmittedQuestion`, per environment, submissions off globally within CloudKit permission propagation, browse unaffected, app shows the existing submit error; restore = re-grant; the `setup`-would-re-grant caveat from the design decisions; explicit statement that CloudKit offers no server-side rate limiting and the client throttle is friction only), this plan doc (completion notes).

**Contract:** a moderator who has never read this plan can respond to a flood end-to-end from docs/moderation.md alone. Wrap: full UI suite green (iPhone), rebase on main, PR `feat: catalog submission rate limiting (plan 38)` referencing #31 — merging it closes the precondition; the open-submissions announcement itself remains a human call on #31.

Verify: `swift test`, full UI suite. Commit `docs: abuse response + emergency lever for catalog submissions (plan 38, #31)`.
