# Dispatch Plan 19: Apple Watch app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an independent (companion-style) watchOS app — quick Yes/No answering and minimal report filing from the wrist, complications via WidgetKit accessory widgets, prompt notifications on the watch via automatic forwarding — synced through the existing private CloudKit database.

**Design doc (read first, it carries the citations and the tradeoff record):** `docs/superpowers/specs/2026-07-10-watch-app-design.md`. Tracks GitHub issue #7 — reference it in commits/PRs; do NOT close it from this plan (it covers the whole watch effort).

## Design decisions (decide + log)

- **Independent watchOS app + CloudKit, NOT WatchConnectivity.** The watch is a third device in the already-hardened sync mesh: own local SwiftData store in the watch-side app-group container, `cloudKitDatabase: .private(SyncPolicy.containerIdentifier)`. WatchConnectivity is not used anywhere in v1 (Apple: independent apps "can't rely on the Watch Connectivity framework"; CloudKit is the named sync path — see design doc citations).
- **App Groups are per-device.** The watch app + watch widget extension share the *watch's* `group.io.robbie.Dispatch` container; nothing is shared with the phone through it. No code or comment may imply cross-device container sharing.
- **Notifications: scheduling authority stays 100% phone-side.** iOS local notifications forward to the watch automatically per the system's lock-state rules (doc-cited in the design). The watch app schedules NOTHING in v1 — watch-local scheduling would double-prompt. The watch app's notification delegate only routes taps/actions on forwarded notifications to the right question screen.
- **Quick answer files locally on the watch; the phone reconciles via sync.** The widget's pending-action-marker trick is phone-process-only and does not exist on watch. Verify the phone's remote-change pipeline (`RemoteChangeObserver` → replan callback) cancels pending nags / updates `lastActedAt` when a report arrives via sync; if that link is missing, add it phone-side (kit-tested), because watch-filed reports must quiet nags exactly like phone-filed ones.
- **New targets:** `DispatchWatch` (watchOS application, bundle ID `io.robbie.Dispatch.watchkitapp`, `WKApplication`/`WKCompanionAppBundleIdentifier`/`WKRunsIndependentlyOfCompanionApp` Info.plist keys) and `DispatchWatchWidgets` (watchOS WidgetKit extension, `io.robbie.Dispatch.watchkitapp.widgets`). Versions mirror the iOS targets. DispatchKit `Package.swift` gains `.watchOS(.v26)`.
- **Complications:** `accessoryCircular`/`accessoryRectangular`/`accessoryInline`/`accessoryCorner` rendering `WidgetSnapshot` from a read-only shared-store fetch (watch-side mirror of the phone widget architecture). Timeline reloads on watch-app save/foreground.
- **v1 watch UI:** quick-answer front and center, then the enabled-question list with minimal per-type inputs (yes/no, choice, number via crown/stepper, text via system dictation/scribble input). No sensors, drafts, editing, visualizations, or settings beyond a sync-status line. Reports carry `ReportTrigger` attribution — add an additive `.watch` raw value (v2 export tolerance test, same as `.widget` was).
- **Profiles are the known landmine.** Two new bundle IDs → ASC registration + App Group/iCloud capability enablement + two new App Store profiles via the ASC API (curl recipe in the session ledger, 2026-07-08; plan 25 documents the pattern) + two new `provisioningProfiles` entries in `scripts/ExportOptionsUpload.plist`. Archive-prove signing BEFORE the commit that depends on it.

## Global Constraints

- Suites green before every commit; scoped commits + push; `git pull --rebase` before starting/pushing. Test-gating absolute: CloudKit/ubiquity never touched under test args — the watch app takes the same injected-local-store path. Do NOT bump the build number (the controller bumps all four targets together at ship time). Additive schema only — this plan makes NO model changes beyond the additive `ReportTrigger.watch` raw value. Accessibility on new watch UI per the plan-17 bar. Every platform-behavior claim in code comments cites a doc URL (four-strikes rule).

---

### Task 1: Targets, entitlements, kit platform — a watch app that builds and syncs

- [ ] **Files:** `project.yml` (two new targets + scheme wiring + embed), `Package.swift` (`.watchOS(.v26)`), new `Watch/Sources/` (app entry, store construction reusing `StoreLocation`/`SyncPolicy` patterns — extract phone-side store-construction logic into shared code only where it lifts cleanly; otherwise a thin watch-side mirror with the never-fail-launch fallback), new `Watch/Dispatch Watch.entitlements` (app group, CloudKit container, aps-environment), new `WatchWidgets/` skeleton + entitlements (app group only), privacy manifests for both new targets (mirror the existing ones).

**Contract:** `xcodegen generate` + build succeeds for all targets; kit suite green with the watchOS platform added (fix any watchOS-unavailable API in kit via `#if canImport` — expected: none); watch app launches in the simulator to a placeholder list backed by a local test-gated store; store construction logs the same sync-decision story as the phone (`SyncPolicy` semantics: user toggle respected — read from the watch's own defaults, default ON; test environment forces local).

Verify: build (all targets), kit suite, existing UI suite untouched and green. Commit `feat(watch): targets, entitlements, kit watchOS platform` → push.

### Task 2: Provisioning — register, profile, prove

- [ ] **Files:** `scripts/ExportOptionsUpload.plist` (two new profile mappings); session-ledger notes for what was created.

**Contract:** via the ASC API recipe: register bundle IDs `io.robbie.Dispatch.watchkitapp` and `io.robbie.Dispatch.watchkitapp.widgets`, enable App Groups + iCloud (CloudKit) capabilities on the app's bundle ID resource (App Groups only for the widgets) and associate `group.io.robbie.Dispatch` / `iCloud.io.robbie.Dispatch`, create App Store profiles `Dispatch Watch App Store` and `Dispatch Watch Widgets App Store` against the current Apple Distribution cert. `xcodebuild archive` + `-exportArchive` (destination can stay upload — a TestFlight build with the stub watch UI is fine and is the true end-to-end proof) succeed; `codesign -d --entitlements` on the archived watch app shows the app group + CloudKit values. Document every ASC call made.

Verify: archive + export succeed with manual signing; entitlement dump captured in the report. Commit `chore(watch): provisioning + export options for watch targets` → push.

### Task 3: Quick answer + minimal filing UI

- [ ] **Files:** `Watch/Sources/` (home view: quick-answer card + question list, per-type input views, filing flow), `Sources/DispatchKit/` (reuse `WidgetQuickAnswer` eligibility + the shared minimal-report filing function; additive `ReportTrigger.watch` in `Models/Values.swift` + v2 tolerance test), phone-side nag/`lastActedAt` reconciliation on remote report arrival if Task-0 verification (do it here) shows the link missing (`App/Sources/Sync/RemoteChangeObserver.swift` callback → `App/Sources/Notifications/`).

**Contract:** filing re-fetches the question by ID before saving (stale-UI rule); saved reports carry `.watch` trigger; kit tests for the filing function watch-path (report shape, trigger) and for `ReportTrigger` round-trip; the reconciliation behavior (nag cancel on synced report) kit-tested phone-side. Watch UI accessible: labels on all controls, Dynamic Type survives the largest watch setting without clipping.

Verify: build, kit suite, UI suite; manual sim check: file on watch sim → row visible in phone sim app after foreground (shared CloudKit container on sims signed into the same account, or documented as device-script item if sim CloudKit proves flaky — do not fake it). Commit `feat(watch): quick answer + minimal report filing` → push.

### Task 4: Complications + notification routing + wrap

- [ ] **Files:** `WatchWidgets/Sources/` (accessory widget: circular/rectangular/inline/corner over `WidgetSnapshot`, read-only store fetch, reload pokes from the watch app on save/foreground), `Watch/Sources/` (UNUserNotificationCenter delegate: route forwarded prompt-notification taps/actions to the question; NO scheduling calls anywhere in the watch target — grep-provable).

**Contract:** widget timeline renders all four families from a test store; corner family is watchOS-gated correctly so the iOS widget target is untouched; notification routing unit-testable part extracted (identifier → destination mapping) and kit-tested. Wrap: full suites; device-script list appended to the report (watch↔phone CloudKit sync, forwarding behavior on wrist, complication refresh, dictation input) — these are sim-unverifiable per the design doc.

Verify: build (warning-free), kit suite, UI suite, archive green. Commit `feat(watch): complications + notification routing` → push. Whole-branch review follows (controller-driven); build bump for all four targets happens at ship time per standing process.
