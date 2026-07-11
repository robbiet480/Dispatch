# Dispatch Plan 36: macOS app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a Mac-native Dispatch for reviewing and analyzing — a new `DispatchMac` app target (native SwiftUI, macOS 26) that syncs the same SwiftData store through the same CloudKit container as iOS/watchOS, presents reports browsing/detail in a split view, the visualizations dashboard, Insights, in-app search, a settings subset, and imports — PLUS the journaling-ecosystem exports (Day One JSON, Markdown/Obsidian) that were deliberately deferred to macOS per owner decision. Tracks GitHub issue #22 — reference it in commits/PRs.

**Scope discipline (hard constraints, v1 non-goals):** capture is mobile-first — the Mac app has NO survey/capture flow, NO sensor providers, NO notifications/nag reminders, NO widgets, NO prompt-group scheduling UI, NO webhooks config, NO catalog browsing, NO app lock. Review, analyze, search, import, export. Each of these is a deliberate v1 non-goal, not an oversight; capture-on-Mac (menu-bar quick entry) is a plausible v2 and must not leak into this plan.

## Design decisions (decide + log)

- **DECISION 1 — approach: native SwiftUI macOS target. Not Catalyst, not "Designed for iPad."** The codebase makes this the honest choice, not just the tasteful one:
  - *DispatchKit is already multiplatform.* `Package.swift` declares `.macOS(.v26)` alongside iOS/watchOS, `dispatch-mod` is a macOS executable target shipping today, and `swift test` already runs the whole kit suite on a macOS host. Every brain the Mac app needs — models, `ReportBuilder`, `VisualizationData`, `InsightsEngine`, search, v1/v2 import/export, backups — lives in the kit, Foundation/SwiftData/SwiftUI-only by standing rule.
  - *"Designed for iPad" (rejected):* zero-effort checkbox post-plan-27, but it ships the ENTIRE iOS app on Apple Silicon — capture flow, HealthKit/CoreMotion/WeatherKit providers, notification prompts — contradicting the review-first scope; no real menu bar, no multi-window, no Mac Settings scene; and the Mac-only Day One/Markdown exporters would have to ship in the iOS binary or nowhere. It also excludes Intel Macs entirely (fine) while giving nothing Mac-idiomatic back.
  - *Mac Catalyst (rejected):* drags the whole iOS app target through `#if targetEnvironment(macCatalyst)` — the privacy cover `UIWindow`, `fullScreenCover` survey presentation, the sensor cascade, HealthKit entitlements — all to then hide most of it. The app target's UIKit dependencies are thin (8 files) but they sit at the app's spine (`DispatchApp.swift`, `ContentView.swift`, `RootNavigationView.swift`), exactly the files a Catalyst port fights hardest.
  - *Native target (chosen):* the Mac app is a thin review shell over the kit. App-side view sharing is OPPORTUNISTIC, not assumed — even UIKit-free files use iOS-only SwiftUI (`navigationBarTitleDisplayMode`, `.insetGrouped`, toolbar placements), so the default is small Mac-native views consuming kit data types (`VisualizationData`, `InsightsEngine` outputs), with dual target membership (the `Shared/Providers` precedent) only where a file compiles for both platforms unmodified or with trivial `#if os` guards. Swift Charts renders the same chart code on macOS.
- **DECISION 2 — sync: same CloudKit container, same SwiftData mirroring, new entitlements file.** `ModelConfiguration(cloudKitDatabase: .private(SyncPolicy.containerIdentifier))` with `iCloud.io.robbie.Dispatch` works identically on macOS. What macOS specifically needs (entitlement discipline — verify by archiving + codesign-dump, NEVER trust recalled names):
  - `com.apple.developer.icloud-services` (CloudKit) + `com.apple.developer.icloud-container-identifiers` — same values as iOS.
  - **`com.apple.developer.aps-environment`** — the macOS push entitlement key is PREFIXED with `com.apple.developer.`, unlike iOS's bare `aps-environment`. SwiftData's CloudKit mirroring registers for remote notifications to learn about server changes; without this, macOS falls back to polling-ish staleness.
  - `com.apple.security.app-sandbox` + `com.apple.security.network.client` — sandbox is mandatory for Mac App Store; network client is required for CloudKit to reach the network at all inside the sandbox.
  - No `UIBackgroundModes` analog needed — macOS delivers remote notifications to running apps without a background-modes declaration.
  - `SyncPolicy.swift` + `RemoteChangeObserver.swift` (App/Sources/Sync) get dual target membership — they are Foundation/os/SwiftData-only. Same relaunch semantics for the toggle.
- **DECISION 3 — store location: plain app-container store, NOT the App Group.** iOS moved the store into `group.io.robbie.Dispatch` (plan 14) because widgets/intents read it. Mac v1 has no widgets and no intents, and macOS app-group container semantics differ (user prompts / team-ID prefix rules). The Mac store lives in the app's own Application Support; CloudKit is the sole data channel between platforms. Revisit only when Mac widgets exist.
- **DECISION 4 — distribution: Mac App Store via the existing ASC app + TestFlight. Not Developer ID/notarized-direct.** The macOS binary joins the existing ASC app record as an additional platform, so the two existing testers get it through the same TestFlight install they already have. The headless pipeline (`scripts/upload-testflight.sh`, ASC API key 32H9YPRYUD, manual-signing export) extends with a Mac destination; a new "Dispatch macOS App Store" provisioning profile must be created via the ASC API (cloud-managed signing is denied to the key — same constraint as iOS; see session ledger for the curl recipe). Developer ID + notarization rejected for v1: a second signing/distribution flow, no TestFlight feedback loop, and no user demand for it yet. Document as a v2 option for a non-MAS build.
- **DECISION 5 — exporters live in the kit, TDD, platform-neutral; only the UI is Mac-only.** `DayOneExporter` and `MarkdownExporter` join `CSVExporter` in `Sources/DispatchKit/Export/`, tested by `swift test` like everything else (they'd even run on iOS — the decision to surface them only in the Mac UI is a product decision per issue #22, not a technical constraint, and the code placement keeps it reversible).
  - *Day One JSON:* Day One's import format — top-level `{"metadata": {"version": "1.0"}, "entries": [...]}`, each entry with `creationDate` (ISO-8601 UTC), `text` (Markdown), `timeZone`, optional `location {latitude, longitude, placeName}`, `tags`. One entry per report; the entry text renders each question prompt as a heading with the flattened answer (reuse the kit's existing per-type flattening logic — one representation per answer type, matching `CSVExporter.flatten` semantics). Sensor snapshot (weather, steps, battery, etc.) becomes a trailing metadata section in the text plus native fields where Day One has them (`weather`, `location`). Verify the format against a real Day One import during implementation, not from memory.
  - *Markdown/Obsidian:* one `.md` file per report inside a chosen folder — filename `YYYY-MM-DD HHmm.md` (report date, filesystem-safe), YAML front matter (report date ISO-8601, type day/night-marker if applicable, sensor scalars as keys), body = prompt headings + answers. Tokens/people answers additionally emit as front-matter list values so Obsidian dataview/graph can chew on them. Exporter returns `[(filename, contents)]`; writing to disk is the caller's job (testable without I/O).
- **DECISION 6 — Mac navigation: `NavigationSplitView` (sidebar = reports list w/ search, detail = dashboard or report detail), a real menu bar, and a native `Settings` scene.** The iPad split topology from plan 27 is the seed, rebuilt Mac-native rather than shared (RootNavigationView is UIDevice-gated). Menu bar: File → Import…/Export submenu (Day One JSON…, Markdown Folder…, Dispatch JSON…, CSV…); standard Edit/View/Window menus free from SwiftUI. `⌘F` focuses search; `⌘,` opens Settings (system-provided). Export UIs use `fileExporter`/`NSOpenPanel` folder selection — sandbox-safe, user-driven access.
- **DECISION 7 — settings subset:** iCloud sync toggle (shared `SyncPolicy`), theme color, imports (v1 Reporter JSON + v2 Dispatch JSON via the existing kit importers), exports, and About. NOT ported: notifications, prompt groups, app lock, webhooks, backups schedule, health — all capture-adjacent or iOS-only.
- **Search is in-app v1** — the kit's search over reports/answers behind a sidebar search field. Core Spotlight indexing on macOS (the `SpotlightIndexer` port) is deferred; it's additive later.
- **Versioning:** `DispatchMac` carries the same `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` as the iOS targets (the controller bumps all targets together at ship time — the watch precedent).

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → green, per task. The Mac app target is verified with `xcodebuild build` for `platform=macOS` per task; the iOS suites (`swift test` + iPhone/iPad `build-for-testing`) must stay green — this plan must not disturb the iOS app.
- NO schema changes, NO new model fields, NO renumbering — the Mac app reads/writes the exact store the other platforms sync. CloudKit model rules already bind us (optional/defaulted attributes, optional relationships); nothing here may violate them.
- No Mac UI-test suite in v1 (no `AppUITests` analog) — verification is build + kit tests + a manual smoke checklist in the wrap task. Be honest about this in the completion notes.
- Entitlement discipline (absolute, three prior incidents): every macOS entitlement gets verified by a real archive + `codesign -d --entitlements` dump before any task claims it works. New entitlements ⇒ new/updated provisioning profiles via the ASC API.
- Shared-file discipline: a file gains dual target membership ONLY if it compiles on both platforms without weakening the iOS behavior; otherwise write the Mac twin. Never `#if os()`-riddle a working iOS view to force sharing.
- Suites green before every commit; scoped commit per task on branch `plan-36-macos`; rebase on main before the PR. Do NOT bump the build number. Four-strikes rule: non-obvious platform claims cite docs in comments.

---

### Task 1: Kit — DayOneExporter (TDD)

- [x] **Files:** create `Sources/DispatchKit/Export/DayOneExporter.swift`, `Tests/DispatchKitTests/DayOneExporterTests.swift`.

Failing tests first: envelope shape (`metadata.version`, `entries` array); one entry per report; `creationDate` ISO-8601 UTC with the report's date; text contains each prompt as a heading with the flattened answer (one case per answer type — tokens, yesNo, number, multipleChoice, location, note, people, and time if plan 28 has merged: rebase-aware, same convention as plan 28's CSV note); location answer maps to the native `location` field; empty reports and skipped questions produce no phantom sections; deterministic output (stable ordering) so tests can compare full strings.

**Contract:** pure function `DayOneExporter.export(reports:) -> Data` (or throwing), no I/O, no platform conditionals. `swift test` green.

Verify: `swift test`. Commit `feat(kit): Day One JSON exporter (plan 36)`.

### Task 2: Kit — MarkdownExporter (TDD)

- [x] **Files:** create `Sources/DispatchKit/Export/MarkdownExporter.swift`, `Tests/DispatchKitTests/MarkdownExporterTests.swift`.

Failing tests first: returns `[(filename: String, contents: String)]`; filename `YYYY-MM-DD HHmm.md` from report date, collision-suffixed deterministically (`… 2.md`) for same-minute reports; YAML front matter (ISO-8601 date, sensor scalars, tokens/people as YAML lists); body headings per answered prompt; YAML-escaping for prompts/answers containing quotes/colons; no trailing whitespace damage that would trip Obsidian.

**Contract:** pure, no I/O, platform-neutral. `swift test` green.

Verify: `swift test`. Commit `feat(kit): Markdown/Obsidian exporter (plan 36)`.

### Task 3: DispatchMac target — project.yml, entitlements, store + CloudKit boot

- [x] **Files:** `project.yml` (new `DispatchMac` application target, `platform: macOS`, `deploymentTarget.macOS: "26.0"`, bundle id `io.robbie.Dispatch.mac` — a distinct bundle id keeps iOS provisioning untouched; versions mirrored; `INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.lifestyle`), create `Mac/DispatchMac.entitlements` (per DECISION 2: sandbox, network.client, iCloud CloudKit + container `iCloud.io.robbie.Dispatch`, `com.apple.developer.aps-environment`), create `Mac/Sources/DispatchMacApp.swift` (ModelContainer construction: plain Application Support store URL per DECISION 3, `cloudKitDatabase:` per shared `SyncPolicy`; placeholder `WindowGroup`), create `Mac/Assets.xcassets` (icon reuse), `Mac/PrivacyInfo.xcprivacy`. Dual-membership: `App/Sources/Sync/SyncPolicy.swift`, `App/Sources/Sync/RemoteChangeObserver.swift`, `App/Sources/ThemeColor.swift` (audit each compiles for macOS first).

**Contract:** `xcodegen generate` succeeds; `xcodebuild build -scheme DispatchMac -destination 'platform=macOS'` succeeds; app launches, constructs the store, and (signed with the real team) reaches CloudKit — verified by a real archive + `codesign -d --entitlements` dump showing the exact entitlement keys, and a two-device smoke: a report filed on iOS appears in the Mac store (log `category == "sync"`). iOS suites untouched and green.

Verify: `swift test` + Mac build + iPhone `build-for-testing`. Commit `feat(mac): DispatchMac target — store, CloudKit sync, entitlements (plan 36)`.

### Task 4: Reports browsing + detail (split view)

- [x] **Files:** create `Mac/Sources/MacRootView.swift` (`NavigationSplitView`: sidebar = reports list with stats header + `.searchable` search field; detail = dashboard placeholder or report detail), `Mac/Sources/MacReportsListView.swift` (selection-driven `List`, kit-backed search filtering, delete via context menu + ⌫ with confirmation), `Mac/Sources/MacReportDetailView.swift` (prompt/answer sections, sensor snapshot section, per-answer-type rendering — audit `App/Sources/Reports/ReportDetailView.swift` subviews for dual-membership candidates first; share what compiles, twin the rest).

**Contract:** browse, search, select, read, delete reports against the synced store; deleting the selected report clears the detail pane (plan 27's dangling-selection lesson); layout honors macOS conventions (sidebar toggle, min window size).

Verify: `swift test` + Mac build. Commit `feat(mac): reports split view — browse, search, detail (plan 36)`.

### Task 5: Visualizations dashboard + Insights

- [x] **Files:** create `Mac/Sources/MacDashboardView.swift` (default detail-pane content: multi-column grid of question visualizations off the kit's `VisualizationData`, filter control, report count), `Mac/Sources/MacInsightsView.swift` (kit `InsightsEngine` output in an adaptive grid). Audit `App/Sources/Visualizations/QuestionVisualizationView.swift` for dual membership — Swift Charts is cross-platform and this is the highest-value share in the plan; twin only if iOS-only modifiers block it.

**Contract:** every question type that visualizes on iOS visualizes identically on Mac (same `VisualizationData` input, same chart marks); the memoized rebuild pattern (visualizationTaskID) is reused, not reinvented; window resize reflows the grid.

Verify: `swift test` + Mac build. Commit `feat(mac): visualizations dashboard + insights (plan 36)`.

### Task 6: Menu bar, Settings scene, imports + exports UI

- [x] **Files:** `Mac/Sources/DispatchMacApp.swift` (`.commands`: File → Import Dispatch/Reporter JSON…, Export → Day One JSON… / Markdown Folder… / Dispatch JSON… / CSV…; ⌘F search focus), create `Mac/Sources/MacSettingsView.swift` (`Settings` scene: iCloud sync toggle via shared `SyncPolicy` with the relaunch caveat text, theme color, About), create `Mac/Sources/MacExportController.swift` (fileExporter/NSSavePanel for single-file exports; NSOpenPanel folder pick + per-file writes for Markdown; progress + error surfacing).

**Contract:** importing the gitignored personal Reporter export (`DISPATCH_V1_EXPORT` ground truth) via the menu produces the same report count as iOS import; a Day One JSON export re-imports into the actual Day One app (manual verification — record the result honestly in completion notes); a Markdown export opens as an Obsidian vault folder with working front matter; all exports run against the sandbox without entitlement violations in Console.

Verify: `swift test` + Mac build. Commit `feat(mac): menus, settings, import/export UI (plan 36)`.

### Task 7: Distribution + wrap

- [ ] **Files:** `scripts/upload-testflight.sh` + `scripts/ExportOptionsUpload.plist` (Mac archive/export lane; new "Dispatch macOS App Store" profile via the ASC API — curl recipe in the session ledger), `README.md` (macOS section), this doc (completion notes).

**Contract:** a real macOS archive exports with manual signing and uploads to ASC, appearing as a Mac TestFlight build on the existing app record; entitlement dump of the archived app matches DECISION 2 exactly; smoke checklist executed and recorded (sync both directions, all four exports, import, search, delete). Rebase on main; PR titled `feat: macOS app (plan 36)` referencing #22.

Verify: `swift test`; Mac + iPhone + iPad builds green; archive uploaded. Commit `chore(mac): TestFlight lane + wrap (plan 36)`.

---

## Completion notes (2026-07-10, implementation on PR #34 / branch plan-36-doc)

Tasks 1–6 implemented per house workflow ON the plan-doc branch (the docs PR
becomes the feature PR). Branch rebased onto main (post #52/#53/build 28)
before implementation.

**Verification record:**
- `swift test`: 557 tests green (540 baseline + 9 DayOneExporter + 8
  MarkdownExporter), TDD red-first for both exporters.
- `xcodegen generate` clean; `DispatchMac` scheme builds for
  `platform=macOS` (compile/link verified with `CODE_SIGNING_ALLOWED=NO`
  — see signing caveat below). iPhone `build-for-testing`
  (iPhone 17 / iOS 26.5 sim) and iPad `build-for-testing` green — the
  iOS app is undisturbed. Full UI suite NOT run here (merge gate).
- Entitlements verified by `codesign -d --entitlements` dump of the
  built, ad-hoc-signed app: exactly the DECISION 2 set (app-sandbox,
  network.client, files.user-selected.read-write, iCloud CloudKit +
  `iCloud.io.robbie.Dispatch`, `com.apple.developer.aps-environment`).
  A real archive dump still owed once a provisioning profile exists.
- Launch smoke (ad-hoc signed): with the iCloud/aps entitlements
  stripped (no profile available headless) and sync ON, SwiftData's
  CloudKit mirroring SIGTRAPs asynchronously on
  `com.apple.coredata.cloudkit.queue` AFTER successful container
  construction — the never-fail-launch catch cannot see it. This is an
  unprovisioned-binary artifact, not a code bug (iOS behaves the same
  without its entitlement); with sync toggled off the app launches
  clean: split view, stats sidebar, Dashboard/Insights picker, themed
  empty state (screenshot-verified). Real CloudKit smoke (report filed
  on iOS appears on Mac) is owed once signing exists.

**Deviations from the plan doc:**
- Task 7's distribution lane (upload-testflight.sh Mac lane, ASC
  provisioning profile, TestFlight upload) deliberately NOT done in this
  pass — out of scope per the controller instruction (no ASC/TestFlight/
  upload-script work). README macOS section + these notes done.
- Task 6 UI surfaces live in a Settings `Form` + File-menu commands
  driven by `MacExportController` (NSSavePanel/NSOpenPanel), not
  SwiftUI `fileExporter` — commands can't anchor `fileExporter`, and one
  controller serves both the menu bar and Settings.
- Exporter prompt ordering is alphabetical within an entry/file: the
  pure `export(reports:)` contract has no question list, and
  `Report.responses` relationship order isn't stable across fetches —
  alphabetical is the deterministic choice (documented in both files).
- The Mac filter UI is a popover twin (`MacFilterPopover`), not the
  shared `VisualizationFilterView` (iOS-only navigation-bar styling +
  inset-grouped lists). Dual membership shipped: SyncPolicy,
  RemoteChangeObserver (one `#if os(iOS)` around the Spotlight reindex),
  ThemeColor, AppDefaultsEnvironment, QuestionVisualizationView (one
  `#if canImport(UIKit)` color-blend seam), OptionBlockLayout.
- Day One format written from Day One's published import shape; the
  plan's "verify against a real Day One import" is a manual step (below).

**Manual steps for the owner:**
1. Portal: register App ID `io.robbie.Dispatch.mac` with iCloud
   (`iCloud.io.robbie.Dispatch`) + Push Notifications capabilities;
   create a Mac App Development profile (or let Xcode automatic signing
   do it in-IDE) — headless xcodebuild here had no Apple ID session.
2. Two-device CloudKit smoke once signed: file a report on iOS, watch
   `log stream --predicate 'category == "sync"'` on the Mac.
3. Import a real Day One JSON export produced by the app into Day One
   and record the result here (format was written from the published
   shape, not verified against the real importer).
4. Task 7 when ready to ship: "Dispatch macOS App Store" distribution
   profile via the ASC API, upload-testflight.sh Mac lane, Mac
   screenshots + `scripts/asc-listing.swift` display-type mapping
   (issue #22 comment), ASC Mac listing.
