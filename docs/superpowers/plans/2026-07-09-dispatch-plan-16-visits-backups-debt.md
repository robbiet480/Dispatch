# Dispatch Plan 16: Visit triggers, automatic backups, debt cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) the last unbuilt idea from the original modernization brainstorm — prompt groups triggered by **arriving somewhere** (significant-visit monitoring); (2) **automatic rotating backups** of the v2 export; (3) the accumulated small-debt cleanup.

## Hard constraint for this whole plan

**NO new entitlements.** The App Store provisioning profiles are manually created and pinned (scripts/ExportOptionsUpload.plist); an entitlement change breaks the headless upload until profiles are recreated. Everything below is designed to fit inside the current entitlement set — if an approach turns out to need one, STOP that item, document, and continue with the rest.

## Design decisions (decide + log)

- **Visit trigger = `CLLocationManager.startMonitoringVisits()`** (classic visits API: delivers CLVisit on arrival/departure, relaunches the app in the background, needs **Always** location authorization but — per Apple's documented behavior for visit monitoring — NOT the `location` UIBackgroundModes entry; verify against current docs and do not add background modes). New `GroupSchedule` event case `visitArrival` (raw "visitArrival") alongside workoutEnd; planner returns [] (event-driven).
- **Always-authorization is asked lazily and contextually:** ONLY when the user enables a visit-triggered group (editor flow explains why, then requests the Always upgrade; requires `NSLocationAlwaysAndWhenInUseUsageDescription` — a purpose string, not an entitlement). Never part of onboarding/top-up; users without visit groups are never asked. Denied/when-in-use-only → the group shows an inline "needs Always location" hint and simply doesn't fire.
- **Arrival semantics:** on a CLVisit whose departureDate is distantFuture (= arrival), if awake and any enabled visitArrival group exists (and the focus filter allows it): post an immediate `gprompt-<groupID>-<arrival stamp>` notification (content-addressed → duplicate deliveries dedupe). Persist last-handled arrival date to skip stale/duplicate visits. Report attribution: `ReportTrigger` gains `.visitArrival` (additive raw value; v2 tolerant both ways, same as workoutEnd).
- **Backups are foreground-scheduled, not background-tasked** (no BGTaskScheduler → no Info.plist task identifiers, no background-mode additions): on scene-active (debounced) and after report save, if the newest backup is >20h old → write a full v2 export to `Documents/Backups/dispatch-backup-YYYY-MM-DD-HHmm.json`; keep newest 14, delete older. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` Info.plist keys make Documents visible in the Files app ("On My iPhone → Dispatch") and Finder — plain plist keys, no entitlement. Backup writing runs off-main (background ModelContext, same pattern as import/remote-change).
- **Sync is not backup:** README gets a sentence making the distinction explicit.

## Global Constraints

- No delegation; suites green before every commit (261 kit + 11 UI at start); commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is the repo owner's standing instruction). Test-gate all monitoring/scheduling as usual. Do NOT bump the build number.

---

### Task 1: Kit — visitArrival schedule kind + backup rotation logic

**Files:** `Sources/DispatchKit/Models/PromptGroup.swift` (GroupSchedule case), `Sources/DispatchKit/Models/Values.swift` (ReportTrigger.visitArrival), `Sources/DispatchKit/V2/*` (tolerance), new `Sources/DispatchKit/Backup/BackupRotation.swift`; tests.

**Contract:**
- `GroupSchedule.event` gains the visitArrival kind (or a parallel case — match the existing workoutEnd shape exactly); unknown-raw forward-compat preserved; GroupPlanner returns [] for it (test).
- `ReportTrigger.visitArrival` additive; v2 round-trip + old-fixture tolerance tests.
- `BackupRotation`: pure helpers — `isDue(lastBackupDate:now:threshold:)`, `filesToDelete(existing:keep:)` (sorted by encoded timestamp in filename, newest N kept), `backupFilename(for date:)` (deterministic format). Tests: due/not-due boundaries, rotation ordering, filename round-trip.

Verify: `swift test`. Commit `feat(kit): visit-arrival schedule kind + backup rotation` → push.

### Task 2: App — visit observer + editor integration

**Files:** new `App/Sources/Providers/VisitObserver.swift`; `App/Sources/Settings/PromptGroupsView.swift`/editor (schedule option "When I arrive somewhere" + Always-auth request flow + needs-Always hint); `App/Sources/Notifications/NotificationScheduler.swift` (shared immediate-gprompt path reuse); `project.yml` (NSLocationAlwaysAndWhenInUseUsageDescription); `App/Sources/DispatchApp.swift` (observer lifecycle — started at launch when any visit group enabled, refreshed on group edits AND on remote-change sync, mirroring WorkoutEndObserver).
- Always-auth request uses a dedicated CLLocationManager delegate (single-resume guarded — use OneShotResumeGuard; this session shipped a double-resume crash once).
- Focus filter state respected (muted visit group doesn't fire). Awake-gated. Test-gated.
- UI test: create a visit group via the editor under --mock-sensors (no real auth dialog), assert it appears with the schedule label.

Verify: build, kit suite, UI suite (11+1). Commit `feat: visit-arrival prompt groups` → push.

### Task 3: App — automatic backups

**Files:** new `App/Sources/Backup/BackupManager.swift`; `App/Sources/Settings/DataSettingsView.swift` (Backups section: enabled toggle default ON, last-backup caption, count, "Back Up Now" button, identifier `backup-now`); `project.yml` (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace); `App/Sources/DispatchApp.swift` (scene-active hook); README (backups section + sync-is-not-backup note).

**Contract:**
- BackupManager: off-main export via background ModelContext + V2Exporter to Documents/Backups; rotation via kit BackupRotation (keep 14); `backupLog` OSLog category; failures logged, never user-blocking; skipped entirely in test environment (except a unit-testable path with injected directory).
- Trigger points: scene-active (debounced, >20h stale check) + after report save (same staleness check — a backup at most daily). Manual "Back Up Now" ignores staleness.
- Verify in Files-app terms: build, then check the built app's Info.plist carries both keys (plutil, same as the display-name check).

Verify: build, kit suite, UI suite. Commit `feat: automatic rotating backups` → push.

### Task 4: Debt cleanup + wrap

**Files:** as found — `App/Sources/Visualizations/QuestionVisualizationView.swift` (deprecated `Text` concatenation), `App/Sources/Notifications/NotificationScheduler.swift` (actor-isolation warnings; nonisolated parsing helpers per the build-4 review's Swift-6 note), `.github/workflows/ci.yml` (cache SPM/DerivedData between runs — actions/cache keyed on Package.resolved/project.yml), digest sheet/survey cover presentation contention (WeeklyDigestView / ContentView — serialize or document with a guard).

**Contract:**
- Zero compiler warnings on a clean build of app + kit (list any deliberately left, with reasons).
- CI: measurably cached (note the before/after runtime in the report if CI is observable; otherwise structural).
- Wrap: full suites; completion note in this doc.

Verify: build (warning-free), kit suite, UI suite. Commit `chore: warning cleanup, CI caching, presentation guard` → push. Whole-branch review follows (controller-driven).

---

## Completion note (2026-07-09)

All four tasks shipped: 0ff4aa7 (kit), de58877 (visit groups), a4099c2
(backups), + the task-4 commit. Suites at finish: **273 kit + 12 UI**, all
green; clean app + kit builds are warning-free (sole deliberate exception:
the `appintentsmetadataprocessor` "Metadata extraction skipped" log line on
the UI-test bundle — a toolchain notice about a target with no AppIntents
dependency, not a compiler warning). NO new entitlements: verified — only
purpose strings (`NSLocationAlwaysAndWhenInUseUsageDescription`) and plain
plist keys (`UIFileSharingEnabled` via App/Info.plist because it has no
working `INFOPLIST_KEY_*` equivalent; `LSSupportsOpeningDocumentsInPlace`
via build setting; both plutil-verified in the built app). Visit monitoring
ships WITHOUT a UIBackgroundModes entry, per Apple's current
`startMonitoringVisits()` docs (relaunch delivery is intrinsic; the
`location` background mode is for continuous live updates) — citation in
VisitObserver's type doc. CI caching is structural (SwiftPM `.build` +
pinned DerivedData, exact-key + restore-keys); before/after runtimes to be
read off the next few Actions runs. Full report:
`.superpowers/sdd/plan-16-report.md` — device checks for visits/backups
(unsimulatable) are listed there for the owner.
