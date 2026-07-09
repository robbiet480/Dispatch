# Dispatch Plan 13: iCloud sync (SwiftData + CloudKit)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reports, questions, prompt groups, and vocabulary sync across the user's devices via the private CloudKit database, using SwiftData's built-in mirroring. The models were designed CloudKit-compatible from day one (all attributes optional/defaulted, no #Unique, cross-references by uniqueIdentifier string) — this plan wires it up, hardens the seams (dedupe, remote-change reactions, test isolation), and documents the operational steps only the account holder can do.

## Design decisions (decide + log)

- **SwiftData mirroring, not manual CKRecord code.** `ModelConfiguration(cloudKitDatabase: .private("iCloud.io.robbie.Dispatch"))` at container construction. No custom sync engine.
- **Toggle with relaunch semantics.** Settings → iCloud Sync toggle (default **ON** for new installs; existing installs adopt ON at upgrade — sync is the expected behavior and export remains the manual escape hatch). Switching the store between local-only and CloudKit mid-flight means swapping the ModelContainer under live views — fragile; instead the toggle persists to defaults and the container is built accordingly at next launch, with a "Takes effect after reopening Dispatch" footnote. Honest and simple.
- **Test isolation is absolute:** `--ui-testing`/`--mock-sensors` (and `swift test`) always get local, non-CloudKit containers regardless of the toggle. CI never touches CloudKit.
- **Dedupe by uniqueIdentifier.** CloudKit + multi-device (or import on two devices) can materialize duplicates of Questions/PromptGroups/TokenEntity/PersonEntity that share a uniqueIdentifier/text. A kit `SyncDedupe` pass merges them (keep the survivor deterministically — lowest persistent id — and rewrite nothing else since references are by uniqueIdentifier; Response rows reference question prompts/IDs, not object identity). Reports with identical uniqueIdentifier are exact dupes → delete extras. Runs at launch and on remote-change, debounced.
- **Remote-change reactions.** SwiftData doesn't surface CloudKit events directly; listen for `NSPersistentStoreRemoteChange` on the store coordinator (best-effort — if the notification proves unavailable through SwiftData's stack, fall back to scenePhase-active refresh, document which). Debounced handler: SyncDedupe → VocabularyBuilder.rebuild → Spotlight reindex (lock-policy-gated) → notification replan + category re-register (questions may have changed on another device).
- **Entitlements must be archive-proven** (session rule, two prior hallucination incidents): `com.apple.developer.icloud-services` = ["CloudKit"], `com.apple.developer.icloud-container-identifiers` = ["iCloud.io.robbie.Dispatch"], plus `remote-notification` UIBackgroundModes for CloudKit silent pushes (sync-while-backgrounded; without it sync still works foreground-only).
- **Nag/lastActedAt stays device-local** (UserDefaults) — deliberately not synced; each device nags for its own delivered prompts. Notification schedules are re-planned per device from synced Questions/PromptGroups.

## User actions (only the account holder can do these — surface them, don't attempt them)

1. Developer portal: add iCloud capability to the `io.robbie.Dispatch` App ID and create container `iCloud.io.robbie.Dispatch` (like the WeatherKit registration; may take a few minutes to propagate to signing).
2. After first successful on-device run with sync enabled: CloudKit Console → deploy the auto-created schema from **Development to Production** — TestFlight builds sync against Production; skipping this is the classic "works from Xcode, silent no-op on TestFlight" trap.
3. Device smoke: two devices (or device + fresh reinstall) on the same Apple ID — file a report on one, see it on the other; edit a question on one, replan fires on the other.

## Global Constraints

- No delegation by implementers; suites green before every commit (kit + UI at plan start — read the counts from the previous task's report); commit + push per task; `git pull --rebase` before starting/pushing. Pushing to main is the repo owner's standing instruction.
- Zero regression for sync-disabled and test paths: local container behavior byte-identical to today.
- No schema changes in this plan (fields are already compatible); if any model turns out to violate CloudKit rules, fix minimally (optional/default) with a migration-safe change and call it out loudly in the report.

---

### Task 1: Container plumbing + entitlements + sync policy

**Files:** `App/Dispatch.entitlements`, `project.yml` (background mode), `App/Sources/DispatchApp.swift` (container construction), new `App/Sources/Sync/SyncPolicy.swift`; kit untouched.

**Contract:**
- `SyncPolicy` (defaults-backed, appDefaults suite): `iCloudSyncEnabled` default true; test environment forces false. Container construction: enabled && !test → `ModelConfiguration(cloudKitDatabase: .private("iCloud.io.robbie.Dispatch"))`; otherwise current local config. Existing store URL/location unchanged (CloudKit mirroring attaches to the same store).
- Entitlements: icloud-services [CloudKit], icloud-container-identifiers [iCloud.io.robbie.Dispatch]; `UIBackgroundModes: [remote-notification]` via project.yml INFOPLIST keys. **Prove via archive + codesign dump** (team UTQFCBPQRF). If the portal container doesn't exist yet, automatic signing will fail — report the exact error and mark the user-action; keep the code path merge-safe (toggle defaults ON but container falls back to local when CloudKit config throws at startup — wrap construction in do/catch with a logged fallback so the app NEVER fails to launch over sync).
- A `syncLog` OSLog category for every decision (enabled/disabled/fallback/reason).

Verify: build, kit suite, UI suite (unchanged counts), archive+codesign proof (or documented portal blocker with fallback proven by launching with entitlement present but container missing → local fallback logged). Commit `feat: iCloud sync container plumbing + entitlements` → push.

### Task 2: Kit — SyncDedupe

**Files:** new `Sources/DispatchKit/Sync/SyncDedupe.swift` + tests.

**Contract:**
- `SyncDedupe.run(in context: ModelContext) throws -> DedupeSummary`: merge duplicate Questions by uniqueIdentifier (survivor = deterministic pick; union nothing — last-writer-wins per CloudKit is fine, just delete extras), duplicate PromptGroups by uniqueIdentifier, duplicate Token/PersonEntity by text (sum usageCounts into survivor), duplicate Reports by uniqueIdentifier (delete extras). Saves once. Summary counts per type.
- Tests with in-memory contexts: each dup type, no-op on clean store, determinism of survivor choice, counts.

Verify: `swift test`. Commit `feat(kit): sync dedupe pass` → push.

### Task 3: App — remote-change reactions + settings UI

**Files:** new `App/Sources/Sync/RemoteChangeObserver.swift`; `App/Sources/Settings/` (Data or new iCloud section); `App/Sources/DispatchApp.swift` wiring.

**Contract:**
- `RemoteChangeObserver` (test-gated off): subscribes to `NSPersistentStoreRemoteChange` (persistent store coordinator reachable via the container's configurations — verify empirically; if SwiftData blocks access, fall back to scenePhase-active + hourly timer refresh and document). Debounce 2s. Handler (background context where possible): `SyncDedupe.run` → `VocabularyBuilder.rebuild` → Spotlight reindex per lock policy → `NotificationScheduler.replan`.
- Settings: "iCloud Sync" section — toggle (identifier `icloud-sync-toggle`, footnote "Takes effect after reopening Dispatch"), account status row via `CKContainer.accountStatus` ("Available / No iCloud account / Restricted"), and a "Last sync activity" caption fed by the observer's last-event timestamp (best-effort, "—" when none). No blocking calls on main.
- Launch path also runs SyncDedupe once (debounced with the observer's first fire).

Verify: build, kit suite, UI suite (settings nav test extended if the tree test asserts section list — update honestly). Commit `feat: remote-change reactions + iCloud settings` → push.

### Task 4: Docs + wrap

**Files:** `README.md`, this plan doc.

**Contract:**
- README: iCloud section — what syncs (reports, questions, groups, vocabulary), what stays local (nag state, lock, theme — enumerate from the defaults suite), toggle semantics, the Production-schema-deploy step for anyone forking, privacy note (private database only, no shared/public).
- Wrap: full suites; completion note in this doc listing the user-action checklist status.

Verify: build + suites. Commit `docs: iCloud sync` → push. Whole-branch review follows (controller-driven).

---

## Completion note (2026-07-08)

All four tasks shipped (T1 `2e16144`, T2 `1102d25`, T3 `8832c23`, T4 this commit).
Suites at wrap: 217 kit (209 at plan start + 8 SyncDedupe) + 8 UI, all green.
Entitlements archive-proven (codesign dump, team UTQFCBPQRF): icloud-services
[CloudKit], container [iCloud.io.robbie.Dispatch]; UIBackgroundModes
remote-notification landed via a partial `App/Info.plist` merge because
`INFOPLIST_KEY_UIBackgroundModes` is not a recognized build setting.
`NSPersistentStoreRemoteChange` proved reachable through SwiftData's stack
(`--probe-remote-change` diagnostic; fires for own-process saves too, hence the
observer's self-feedback guard and the sync-active subscription gate). CloudKit
container construction fails on a signed-out simulator and falls back to local
with the app launching normally — the never-fail-launch path is empirically
proven.

### User-action checklist status

1. ✅ Developer portal: iCloud capability + container `iCloud.io.robbie.Dispatch`
   created (done before implementation; automatic signing succeeded at archive).
2. ⬜ **CloudKit Console: after the first on-device run with sync enabled, deploy
   the auto-created schema from Development to Production.** Not yet done —
   TestFlight builds silently no-op without it.
3. ⬜ Device smoke: two devices (or device + fresh reinstall) on one Apple ID —
   file a report on one, see it on the other; edit a question on one, replan
   fires on the other.
