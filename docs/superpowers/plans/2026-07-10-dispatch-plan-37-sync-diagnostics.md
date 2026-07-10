# Dispatch Plan 37: Sync diagnostics (issue #23)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an in-app sync diagnostics screen (Settings → iCloud → Diagnostics) so TestFlight sync reports come with evidence instead of anecdotes: account status, a timeline of recent sync events with results, dedupe statistics (SyncDedupe already computes merges — surface the counts), a per-device report provenance breakdown (the plan-19 `sourceDeviceModel`/`sourceDeviceName` fields), and an export-diagnostics button producing a privacy-safe text dump for bug reports. Stalled sync is surfaced HONESTLY — facts observed, never inferred progress.

**Architecture:** kit gets the pure, testable pieces — `SyncEventRecord` (Codable value), `SyncEventLog` (bounded ring buffer + defaults-backed persistence), `DeviceProvenance.breakdown` (pure aggregation over (name, model) pairs), and `SyncDiagnosticsReport.render` (pure string builder whose privacy contract is pinned by tests). App side, a `@MainActor @Observable SyncDiagnostics` owns the log and is fed from two sources: the existing `RemoteChangeObserver` pipeline (store-change events + `DedupeSummary` results — already computed, currently only logged) and — **empirically gated, see the probe decision below** — `NSPersistentCloudKitContainer.eventChangedNotification` for real CloudKit setup/import/export results. A new `SyncDiagnosticsView` renders it all; `ICloudSettingsView` gains the NavigationLink.

**Tech Stack:** SwiftData/CloudKit mirroring (existing, untouched), NotificationCenter (`eventChangedNotification` — observability through SwiftData's stack must be probed), UserDefaults (appDefaults suite) for the persisted ring buffer and cumulative dedupe counters, SwiftUI `ShareLink` for export. NO schema changes, NO new entitlements.

## Design decisions (decide + log)

- **CloudKit event observability is UNVERIFIED until probed — the plan-13 treatment.** SwiftData's CloudKit mirroring is believed to ride `NSPersistentCloudKitContainer` internally, which posts `NSPersistentCloudKitContainer.eventChangedNotification` with an `NSPersistentCloudKitContainer.Event` under `NSPersistentCloudKitContainer.eventNotificationUserInfoKey` (type `.setup`/`.import`/`.export`, `startDate`, `endDate?`, `succeeded`, `error?`). But SwiftData never exposes the container object, so — exactly like `NSPersistentStoreRemoteChange` in plan 13 — the only viable subscription is `object: nil`, and whether the notification fires at all through SwiftData's stack is an empirical question. Task 3 opens with a `--probe-cloudkit-events` diagnostic (the `--probe-remote-change` precedent, which is how plan 13's remote-change claim was proven). **Both outcomes are shipped paths:** observable → the timeline gains real import/export/setup rows with success/failure; not observable → the timeline shows store-change + dedupe rows only, the screen labels itself accordingly (see the honesty decision), and the finding is recorded in a code comment + this plan's completion note. No task other than the probe step depends on the answer.
- **Event vocabulary (kit enum, raw String for wire leniency):** `remoteChange` (an `NSPersistentStoreRemoteChange` burst observed), `dedupePass` (pipeline pass completed; carries the `DedupeSummary` counts and duration), `pipelineError` (pipeline threw; carries sanitized error), `ckSetup` / `ckImport` / `ckExport` (from `eventChangedNotification`, probe-gated; carry `succeeded` + sanitized error). Unknown raws decode and re-encode untouched (the raw-leniency norm) so an older build reading a newer buffer never crashes.
- **Ring buffer: small, persisted, device-local.** Capacity **50** records, JSON-encoded into ONE appDefaults key (`syncEventLog`). Device-local defaults on purpose — diagnostics describe THIS device's observations (the nag-state precedent from plan 13: per-device state stays per-device). Persisted so a "sync broke yesterday" report still has yesterday's tail after relaunch; 50 records × ~120 bytes is well under any defaults-size concern. Corrupt/undecodable stored data → start empty, log, never crash.
- **Cumulative dedupe counters live beside the buffer** (`syncDedupeTotals` key: per-type lifetime counts + last-pass summary + last-pass date). `RemoteChangeObserver` already receives a `DedupeSummary` per pass and only logs it today — the observer starts forwarding every pass (including zero-removal passes, as `dedupePass` events; zero is evidence too) to `SyncDiagnostics`.
- **Provenance breakdown is computed on demand, not cached:** the diagnostics screen fetches Reports in a `.task` and hands `(sourceDeviceName, sourceDeviceModel)` pairs to a kit pure function. Bucket label = `sourceDeviceName ?? sourceDeviceModel ?? "Unknown device"` — generic names ("iPhone", "Apple Watch") are expected until the user-assigned-device-name entitlement lands (see `DeviceIdentity`'s doc comment) and model identifiers ("iPhone17,1") are shown raw (no marketing-name table in v1; additive later). Pre-plan-19 reports have nil in both fields and land in "Unknown device" — the screen footnotes that honestly ("reports filed before device tracking").
- **Honesty rules for status (no fake progress):** the screen shows only observed facts — no spinner, no "Syncing…", no percent. The plan-13 "Last sync activity" caption is relabeled to what it actually is: **"Last store change observed"**. If the probe succeeds, a separate "Last CloudKit export/import" pair with success/failure appears — THOSE are real sync results. Stall surfacing is a fact-conjunction, not an inference: when sync is enabled AND account status is `.available` AND no `ckExport`/`ckImport` (probe path) — or no `remoteChange` (fallback path) — has been observed for the session, the screen states exactly that ("Sync is on and iCloud is reachable, but no sync events have been observed since launch."), with a note that first-launch backfill and quiet stores are normal. No "stalled" badge, no red alarm — a sentence of evidence.
- **Privacy contract for the export (pinned by tests):** the dump contains app version/build, OS version, device model, sync toggle + effective policy, account status, the event ring buffer, dedupe totals, and provenance counts. It NEVER contains report content, answers, question prompts, token/person vocabulary, or health data — nothing from inside a Report beyond its existence count per device. Errors are sanitized to `domain(code): localizedDescription` truncated to 200 chars (CloudKit record names are UUIDs, but truncation + no-userInfo keeps the guarantee structural). A kit test renders a report from fixtures containing a sentinel answer string and asserts the sentinel does NOT appear — the privacy claim is executable.
- **Export mechanism: `ShareLink` over a rendered `String`** (filename suggestion `dispatch-sync-diagnostics.txt` via `SharePreview`). No file written to disk by us, no new file-handling code paths; the user routes it to Mail/Messages/Files themselves.
- **Conflict surfacing in v1 = dedupe evidence, not a resolution UI.** Issue #23 says "conflict surfacing"; SwiftData/CloudKit resolves field conflicts last-writer-wins and the only user-visible conflict artifact Dispatch produces is duplicate rows, which SyncDedupe merges. v1 therefore surfaces WHAT WAS MERGED (counts per type, last pass). A record-level conflict inspector would require manual CKRecord machinery plan 13 deliberately rejected — out of scope, noted for a future plan.
- **`RemoteChangeObserver` keeps its job; `SyncDiagnostics` is a sink, not a second observer of store changes.** The observer gains an injected `onDiagnosticsEvent: @MainActor (SyncEventRecord) -> Void` callback (test default: no-op) invoked at event-observation and pipeline-completion points. The probe-gated `eventChangedNotification` subscription lives in `SyncDiagnostics` itself (it is not a store-change reaction and must not run the dedupe pipeline). Test gating absolute, both paths: never subscribe under `--ui-testing`/`--mock-sensors`.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate).
- No schema changes, no new entitlements, no Info.plist changes, no new permissions. Additive Swift only.
- Test gating absolute: `--ui-testing`/`--mock-sensors` → no CloudKit calls, no NotificationCenter sync subscriptions (existing `RemoteChangeObserver` gates are the template). The diagnostics VIEW still renders under UI tests (empty log, "—" placeholders) so the settings nav test can reach it.
- Zero behavior change for the sync-disabled path beyond the new read-only screen; the remote-change pipeline's semantics (debounce, self-feedback guard, cooldown) are untouched — diagnostics only observes.
- Every uncertain platform claim is verified during implementation and the finding recorded in a code comment: whether `eventChangedNotification` fires through SwiftData's stack (probe), whether `object: nil` reaches it, and the exact userInfo key/Event shape against the SDK.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.

---

### Task 1: Kit — SyncEventRecord + SyncEventLog ring buffer

**Files:**
- Create: `Sources/DispatchKit/Sync/SyncEventLog.swift`
- Test: create `Tests/DispatchKitTests/SyncEventLogTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `SyncEventKind` (raw String, Codable, Sendable): `remoteChange`, `dedupePass`, `pipelineError`, `ckSetup`, `ckImport`, `ckExport` + `displayName`
- `SyncEventRecord { date: Date, kindRaw: String, succeeded: Bool?, detail: String? }` + `kind: SyncEventKind?` typed accessor (nil for unknown raws), `SyncEventRecord.sanitize(error:) -> String`
- `SyncEventLog { capacity: Int = 50 }` — `append(_:)`, `records: [SyncEventRecord]` (oldest-first), `init(decodingFrom: Data?)`, `encoded() -> Data?`

- [ ] **Step 1: Write the failing tests.** (a) ring semantics — appending `capacity + 10` records keeps exactly `capacity`, oldest dropped, order preserved; (b) round-trip — `encoded()` → `init(decodingFrom:)` reproduces records including `succeeded`/`detail` nils; (c) leniency — a record JSON with `kindRaw: "futureKind"` decodes, `kind` accessor returns nil, re-encode preserves the raw untouched; (d) corrupt data — `init(decodingFrom:)` with garbage bytes and with nil both yield an empty log, never throw; (e) `sanitize(error:)` — an NSError with a 500-char localizedDescription renders `domain(code): ` + description truncated to 200 chars, and userInfo values do NOT appear.
- [ ] **Step 2: Run `swift test` — expect FAIL** (types don't exist).
- [ ] **Step 3: Implement.** Plain Foundation, no SwiftData/CloudKit imports — the kind enum backs onto the raw string per the leniency decision; `SyncEventLog` is a simple struct wrapping `[SyncEventRecord]` with capacity trimming on append. Doc comments carry the privacy note (detail is ALWAYS pre-sanitized by callers via `sanitize(error:)` — never a raw error dump).
- [ ] **Step 4: Run `swift test` — expect PASS** (whole kit suite).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): sync event log ring buffer"` → push.

### Task 2: Kit — provenance breakdown + diagnostics report renderer

**Files:**
- Create: `Sources/DispatchKit/Sync/SyncDiagnosticsReport.swift`
- Test: create `Tests/DispatchKitTests/SyncDiagnosticsReportTests.swift`

**Interfaces:**
- `DeviceProvenance.breakdown(_ devices: [(name: String?, model: String?)]) -> [(label: String, count: Int)]` — bucketed by `name ?? model ?? "Unknown device"`, sorted count-descending then label-ascending (deterministic)
- `DedupeTotals { questions, promptGroups, tokens, people, reports: Int; lastPassDate: Date?; lastPassSummary: DedupeSummary? }` (Codable) + `mutating func absorb(_ summary: DedupeSummary, at: Date)`
- `SyncDiagnosticsReport.render(appVersion:osVersion:deviceModel:syncEnabled:syncActive:accountStatusText:events:dedupeTotals:provenance:generatedAt:) -> String`

- [ ] **Step 1: Write the failing tests.** (a) breakdown — mixed input (named, model-only, nil/nil pairs) buckets and sorts per the decision; empty input → empty array; (b) `absorb` sums per-type counts across passes and records the last-pass summary/date; (c) render — output contains the header fields, one line per event (date, kind displayName or raw for unknown kinds, result, detail), dedupe totals, and provenance counts; (d) **privacy pin** — build inputs whose only user-content vector is the event `detail` and provenance labels, plus a sentinel string `"SENTINEL-ANSWER-TEXT"` planted in a plausible-but-forbidden place (e.g. pass a provenance list built from real fixture reports whose answers contain the sentinel) and assert the rendered dump does NOT contain the sentinel; assert it also never contains the words from a fixture question prompt. This test is the executable form of the privacy decision — it must fail if a future change threads report content into the renderer.
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement.** Pure functions, Foundation only. The renderer takes ALREADY-AGGREGATED provenance tuples — it has no Report parameter by construction, which is the structural half of the privacy guarantee (the test is the behavioral half). ISO 8601 dates in the dump (machine-diffable bug reports).
- [ ] **Step 4: Run `swift test` — expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): sync diagnostics report renderer + provenance breakdown"` → push.

### Task 3: App — SyncDiagnostics model, CloudKit event probe, observer feed

**Files:**
- Create: `App/Sources/Sync/SyncDiagnostics.swift`
- Modify: `App/Sources/Sync/RemoteChangeObserver.swift` (diagnostics callback), `App/Sources/DispatchApp.swift` (construct + wire + environment + probe flag)

**Contract:**
- `SyncDiagnostics` (`@MainActor @Observable`): owns a `SyncEventLog` (loaded from appDefaults key `syncEventLog` at init, persisted on every append) and a `DedupeTotals` (key `syncDedupeTotals`, same lifecycle); exposes `events` (newest-first for the UI), `dedupeTotals`, `lastCloudKitImport/Export: (date: Date, succeeded: Bool)?`, and `record(_ event: SyncEventRecord)`.
- **Probe step (do this FIRST, findings gate the subscription):** add a `--probe-cloudkit-events` launch flag beside `--probe-remote-change`'s machinery that subscribes to `NSPersistentCloudKitContainer.eventChangedNotification` with `object: nil` and logs every delivery (`type`, `succeeded`, `error`) to `syncLog`. Run on a signed-in device/simulator with sync active, save a report, watch for export events. **Record the outcome in a code comment on the subscription site AND in this plan's completion note.** Observable → `SyncDiagnostics.startCloudKitObservation()` ships enabled, mapping Event type/succeeded/error (via `SyncEventRecord.sanitize`) into `ckSetup`/`ckImport`/`ckExport` records. Not observable → the method ships as a documented no-op stub with the probe finding cited, and the UI copy from the honesty decision applies. Verify the exact userInfo key and `Event` property names against the SDK while implementing — do not trust this plan's spelling.
- `RemoteChangeObserver` gains `onDiagnosticsEvent: @MainActor (SyncEventRecord) -> Void` (constructor-injected, default `{ _ in }` so existing tests/wiring compile unchanged): fires a `remoteChange` record in `noteRemoteChange()` (post-guard, beside `lastEventDate`), a `dedupePass` record with counts-in-`detail` after every successful pipeline pass (zero removals included), and a `pipelineError` record with sanitized error in the catch path. NO change to debounce/guard/cooldown logic.
- Wiring in `DispatchApp`: construct `SyncDiagnostics` (test-gated: under `--ui-testing`/`--mock-sensors` it constructs with an isolated/ephemeral defaults suite and NEVER subscribes to notifications), pass its `record` into the observer, call `startCloudKitObservation()` only when `isSyncActive` (the same gate that guards the remote-change subscription — a local-only store has no CloudKit events by definition), inject via `.environment`.

- [ ] **Step 1: Run the probe, record the finding** (code comment + completion note; screenshot/log excerpt in the PR description).
- [ ] **Step 2: Implement `SyncDiagnostics` + observer callback + wiring** per the contract. Dedupe totals absorb every pass summary.
- [ ] **Step 3: Verify** — `swift test` (kit untouched but run anyway), `xcodebuild build-for-testing`, then a manual on-device/simulator pass: file a report, confirm `remoteChange`/`dedupePass` records appear and persist across relaunch; with the probe-positive path, confirm `ckExport` records carry real results.
- [ ] **Step 4: Commit** — `git commit -m "feat: sync diagnostics model + CloudKit event observation (probed)"` → push.

### Task 4: App — SyncDiagnosticsView + export + iCloud settings link

**Files:**
- Create: `App/Sources/Settings/SyncDiagnosticsView.swift`
- Modify: `App/Sources/Settings/ICloudSettingsView.swift` (NavigationLink + relabel), `Tests/UITests` settings-navigation test (extend honestly if it asserts the iCloud screen's row list)

**Contract:**
- `ICloudSettingsView`: relabel "Last sync activity" → **"Last store change observed"** (the honesty decision) and add a DIAGNOSTICS section with `NavigationLink("Diagnostics", destination: SyncDiagnosticsView())`, identifier `sync-diagnostics-link`. Match the existing styling helpers (`settingsLabel`/`sectionHeader`, `.readableColumn()`, theme background).
- `SyncDiagnosticsView` sections, all read-only: **STATUS** (sync toggle state + effective policy, account status via the existing `CKContainer.accountStatus` `.task` pattern — never blocking main, "—" until loaded; the stall sentence from the honesty decision when its fact-conjunction holds); **EVENTS** (newest-first rows from `SyncDiagnostics.events`: relative date, kind displayName — raw string for unknown kinds — success mark, detail caption; empty state "No sync events observed yet"); **DEDUPE** (lifetime per-type merge counts + last pass date/summary; footnote explaining merges are the normal resolution of cross-device duplicates); **DEVICES** (provenance breakdown from a `.task` fetch of Reports → `DeviceProvenance.breakdown`, with the "Unknown device = filed before device tracking" footnote); **EXPORT** (`ShareLink` over `SyncDiagnosticsReport.render(...)` with `SharePreview("Dispatch sync diagnostics")`, identifier `sync-diagnostics-export`, footnote "Contains sync activity and device counts only — never your reports, answers, or health data.").
- Accessibility bar (plan 17): rows carry identifiers/labels; Dynamic Type survives XXL; no color-only success/failure signaling (symbol + text).
- Under `--ui-testing` the screen renders with empty data and no CloudKit account call (the account row shows "—"); extend the settings navigation UI test to push the Diagnostics screen and assert the export button exists.

- [ ] **Step 1: Implement view + link + relabel** per the contract.
- [ ] **Step 2: Verify** — `xcodebuild build-for-testing`; UI suite green (navigation test extended); manual pass on device: sections populate, export produces the dump, dump matches the privacy contract by eyeball too.
- [ ] **Step 3: Commit** — `git commit -m "feat: sync diagnostics screen + privacy-safe export"` → push.

### Task 5: Docs + wrap

**Files:** `README.md` (iCloud section), this plan doc.

- [ ] **Step 1: README** — extend the iCloud section: what the diagnostics screen shows, that the export is privacy-safe (enumerate what it never contains), and that "Last store change observed" ≠ "successfully synced" (with the probe finding determining which stronger signal exists).
- [ ] **Step 2: Completion note in this doc** — probe outcome (observable or not, with evidence), suite counts, and the v2 candidates deliberately deferred: record-level conflict inspector, marketing-name table for model identifiers, stall push-diagnostics (CKContainer status history), surfacing `accountStatus` changes as events.
- [ ] **Step 3: Verify** — full suites. Commit `docs: sync diagnostics` → push. Whole-branch review follows (controller-driven).

---

## Completion note

Implemented on branch `plan-37-sync-diagnostics` (5 task commits), rebased onto
origin/main.

**Kit (Task 1–2):** `SyncEventLog` (bounded ring buffer, capacity 50, JSON
persistence, corrupt/nil → empty, raw-lenient unknown kinds), `SyncEventRecord`
(+`sanitize(error:)` — `domain(code): description` truncated to 200 chars, no
userInfo), `SyncEventKind`, `DeviceProvenance.breakdown` (deterministic
count-desc/label-asc bucketing), `DedupeTotals` (+`absorb`), and
`SyncDiagnosticsReport.render` (no `Report` parameter by construction — the
structural half of the privacy guarantee). `DedupeSummary` gained `Codable`.
The privacy pin is executable: a fixture report carrying a sentinel answer +
prompt is reduced to `(name, model)` pairs and the rendered dump is asserted to
contain neither sentinel.

**App (Task 3–4):** `SyncDiagnostics` (`@MainActor @Observable`) owns the
persisted log + totals (appDefaults keys `syncEventLog`/`syncDedupeTotals`),
fed by `RemoteChangeObserver`'s new `onDiagnosticsEvent`/`onDedupePass`
callbacks (deviation from the plan's single `(SyncEventRecord) -> Void`: a
second `(DedupeSummary, Date) -> Void` hook was needed because absorbing
lifetime totals requires the structured summary, which a text `detail` can't
carry — both default to no-ops). `SyncDiagnosticsView` renders STATUS / EVENTS
/ DEDUPE / DEVICES / EXPORT, all read-only and honest (no fake progress; stall
sentence is a fact-conjunction of sync-active + account-available +
no-events-observed). `ICloudSettingsView` relabels "Last sync activity" →
"Last store change observed" and adds the Diagnostics link.

**PROBE FINDING (`--probe-cloudkit-events`):** the empirical question — does
`NSPersistentCloudKitContainer.eventChangedNotification` fire through
SwiftData's mirroring stack when subscribed with `object: nil`? — was NOT
settled by a live run: the implementation environment has no signed-in iCloud
account, and a simulator without one produces zero events (inconclusive, not
negative). The `--probe-cloudkit-events` harness ships (beside
`--probe-remote-change`) so it can be run on a signed-in device: file a report
and grep console output for `CLOUDKIT-EVENT-PROBE:` lines. The SDK shape WAS
verified against `NSPersistentCloudKitContainerEvent.h` (iPhoneOS 26.5):
userInfo key `eventNotificationUserInfoKey`, `Event` with `type`
(`.setup`/`.import`/`.export`), `startDate`, `endDate?`, `succeeded`, `error?`.
`startCloudKitObservation()` ships ENABLED rather than as a no-op stub, because
the subscription is provably side-effect-free (it records diagnostic rows only
and never drives the dedupe pipeline, unlike `NSPersistentStoreRemoteChange`):
if the notification never fires we simply record no `ck*` rows and the honest
fallback UI copy ("no sync events observed") applies automatically; if it does
fire, the timeline gains real import/export results at no cost. This collapses
the plan's two shipped paths into one safe path plus honest labelling — Robbie
can confirm observability on-device and, if it proves reliable, no code change
is needed (it's already live). Comment at the subscription site cites this.

**Test counts:** kit `swift test` 489 passing (10 suites; +13 new across the
two new suites). App `xcodebuild build-for-testing` green. New UI test
`DispatchUITests/SyncDiagnosticsUITests` passing (navigates Settings → iCloud →
Diagnostics, asserts export control + empty-events state). Full UI suite
reserved for the merge gate per house process.

**Deferred to v2** (deliberately out of scope): record-level conflict inspector
(needs manual CKRecord machinery plan 13 rejected); marketing-name table for
model identifiers (shown raw, e.g. "iPhone17,1"); stall push-diagnostics via
CKContainer status history; surfacing `accountStatus` changes as timeline
events.
