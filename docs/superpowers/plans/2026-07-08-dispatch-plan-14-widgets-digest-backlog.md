# Dispatch Plan 14: Widgets, Control Center, weekly digest, backlog sweep

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the last unbuilt items from the original roadmap ("Plan 6": home-screen widgets, Control Center quick-report, on-device LLM weekly digest) plus the deferred review-minor backlog and flights-descended parity.

## Design decisions (decide + log)

- **Store moves into the App Group; widgets query it directly.** (User decision 2026-07-08, superseding the earlier snapshot-only design: alpha has two testers, the migration risk is acceptable once, and shared store access unlocks richer widgets/extensions later.) At launch, BEFORE container construction: if the store exists at the legacy URL (`Library/Application Support/default.store`) and not at the App Group URL, move `default.store` + `-wal` + `-shm` atomically (FileManager, same volume) to `group.io.robbie.Dispatch`'s container; verify all files present post-move; only then build the ModelContainer at the new URL (both CloudKit and local configs — CloudKit mirroring metadata lives inside the store and survives a path move). Move failure → log loudly and fall back to the legacy URL (never-fail-launch holds; widgets show placeholder). Fresh installs create at the App Group URL directly. Widgets open the shared store with a read-only local configuration (`allowsSave: false`, NO cloudKitDatabase — only the app process mirrors) and compute their entries via `WidgetSnapshot.compute` from fetched reports. The app still calls `WidgetCenter.reloadAllTimelines()` on report save + replan (extensions get no change notifications). The kit `WidgetSnapshot` type stays as the pure compute layer; the JSON file write is dropped.
- **App Group:** `group.io.robbie.Dispatch` — entitlement on BOTH app and widget extension; archive-proven per session rule (App Groups is auto-provisionable by automatic signing; if the portal balks, report exactly).
- **Control Center + Lock Screen:** a `ControlWidget` (iOS 18+ API, we're iOS 26 min) wrapping the existing `StartReportIntent` so one tap opens a new report survey; plus an accessory (lock-screen) widget variant of the main widget.
- **Weekly digest = FoundationModels (Apple Intelligence on-device), with a template fallback.** `SystemLanguageModel.default` availability-checked at runtime; when unavailable (device without Apple Intelligence, model not downloaded), the digest renders a deterministic template summary from the same stats — the feature never looks broken. Digest content: report count vs prior week, top tokens/people/places, mood/State-of-Mind trend, steps/workout aggregates, streak. Prompt instructs the model to write a short second-person weekly reflection FROM THE PROVIDED STATS ONLY (no invention); stats computed kit-side (pure, tested).
- **Digest delivery:** a "Weekly Digest" screen (Home overflow or Settings → entry point) rendering on demand, plus an optional local notification Sunday 7pm (toggle in notification settings, default off) that deep-links to the digest. No background LLM work — generation happens when the screen opens.
- **"N ANSWERS" semantics fix (deferred minor, now resolved against the original):** original Reporter's tokens page counts DISTINCT answer values ("5 ANSWERS" over Nothing(9), Can't remember(1), Car chase(1), Disneyland(1), Unknown(1)) — screenshot IMG_3276 arithmetic proves it (13 total, 5 distinct). Current `totalAnswers` sums counts; fix to distinct-value count.
- **Flights descended:** CMPedometer (`floorsDescended`) alongside the HealthKit flights-climbed reading → "7 STAIRCASES UP · 2 DOWN" parity. New Motion permission: `NSMotionUsageDescription` + a cascade step; sensor toggle default ON with graceful unavailable.
- **Medications capture is IN (user decision, amendment):** the original day-one crash came from putting the medication dose type into the BULK `requestAuthorization` read set (uncatchable NSInvalidArgumentException on device). The implementation must determine the correct authorization path EMPIRICALLY from the iOS 26 SDK headers (HealthKit medication APIs — check for per-object read authorization à la vision prescriptions, `HKUserAnnotatedMedication`/medication dose event APIs and their documented auth requirements) — never re-adding the type to the bulk set. Ships default-OFF behind its sensor toggle with an explicit "Request Medications Access" flow, and stays default-OFF until the repo owner verifies on hardware (sim can't exercise real medication data or reproduce the original crash).

## Global Constraints

- No delegation; suites green before every commit (219 kit + 8 UI at start); commit + push per task; `git pull --rebase` before starting/pushing (another agent may land `aps-environment` in App/Dispatch.entitlements early in this plan's life — always rebase before touching entitlements). Pushing to main is the repo owner's standing instruction.
- New target = project.yml changes via XcodeGen only; CI must still build (widget extension included in the archive but NOT in the UI-test scheme's test action).
- All new scheduling/notifications test-gated as usual. Entitlements archive-proven. No store schema changes.

---

### Task 1: Kit — widget snapshot + digest stats

**Files:** new `Sources/DispatchKit/Widgets/WidgetSnapshot.swift`, `Sources/DispatchKit/Digest/DigestStats.swift` + tests.

**Contract:**
- `WidgetSnapshot`: Codable (lastReportDate, todayCount, streakDays, nextPromptDate); `WidgetSnapshot.compute(reports:now:calendar:)` pure + tested (streak = consecutive days ending today/yesterday with ≥1 report); `write(to:)/read(from:)` file helpers (atomic write).
- `DigestStats.compute(reports:weekEnding:calendar:) -> DigestStats`: report count + prior-week delta, top 5 tokens/people/places with counts, numeric-question weekly averages, State-of-Mind valence trend when present, steps/workout totals, streak. Pure + tested (fixture week).
- `DigestStats.templateSummary` — deterministic prose fallback (tested for stability).
- Tokens viz fix: distinct-value count for "N ANSWERS" (change where `totalAnswers` is computed; update its test to the IMG_3276 semantics).

Verify: `swift test`. Commit `feat(kit): widget snapshot + digest stats` → push.

### Task 2: Widgets + Control Center extension

**Files:** `project.yml` (new `DispatchWidgets` app-extension target, App Group entitlements for BOTH targets), new `Widgets/` sources (bundle: main widget with systemSmall/systemMedium + accessory variants, ControlWidget wrapping StartReportIntent), `App/Sources/` snapshot-writer wiring (report save path + replan → write snapshot + reload timelines; App Group container URL helper), `App/Dispatch.entitlements` (+ App Group — REBASE FIRST, aps-environment may have landed).

**Contract:**
- Widget shows time since last report + today's count (medium adds streak + next prompt time); accessory rectangular/circular for lock screen; taps deep-link into the app (main → open app; a "New Report" button/intent where the family supports interactive widgets).
- Control Center control launches StartReportIntent (opens app to survey — existing behavior).
- Snapshot written on: report save (all paths — grep ReportBuilder.save call sites), replan completion, app foreground. Widget reads snapshot only; missing snapshot → placeholder state.
- Archive-prove BOTH targets' entitlements (App Group on each, aps-environment intact on the app). CI: ensure `xcodebuild build` for the app scheme still succeeds on the simulator destination with the new target present.

Verify: build, kit suite, UI suite, archive + codesign dumps (app AND appex). Commit `feat: home/lock widgets + Control Center quick report` → push.

### Task 3: Weekly digest UI + optional notification

**Files:** new `App/Sources/Digest/WeeklyDigestView.swift` (+ generator), Home/Settings entry point, `App/Sources/Notifications/` (digest notification toggle + Sunday 19:00 schedule, identifier `digest-` prefix, joins the existing removal batch), NotificationSettingsView row.

**Contract:**
- Digest screen: stats header (counts, deltas, top lists — from DigestStats), then the narrative: FoundationModels `SystemLanguageModel` when `.available` (availability-switch, generation with a strict stats-only instruction prompt, ~150 words, streamed into the view), else `templateSummary`. Regenerate button. Never blocks main (async generation, progress state). A `digestLog` OSLog category records availability decision + generation timing.
- Optional weekly notification (default OFF): Sunday 19:00 local, `digest-weekly` identifier, removal-batch integrated, tapping deep-links to the digest screen. Test-gated.
- UI test: digest screen opens and renders the template path under `--mock-sensors` (LLM unavailable in sim → fallback exercises deterministically).

Verify: build, kit suite, UI suite (8+1). Commit `feat: on-device weekly digest` → push.

### Task 4: Backlog sweep + wrap

**Files:** per item — `App/Sources/Providers/` (new PedometerProvider), `Sources/DispatchKit/Capture/SensorSettings.swift`, `App/Sources/Privacy/PermissionCascade.swift`, `project.yml` (NSMotionUsageDescription), `App/Sources/Reports/ReportDetailView.swift` + checklist (stairs down display), `App/Sources/Visualizations/VisualizationFilterView.swift` (year source), `App/Sources/HomeView.swift` (filter pill).

**Contract:**
- **Flights descended:** `SensorKind.stairs`… no — keep `healthFlights` for climbed; add readings `flightsDescended` via CMPedometer query for the same window when Motion is authorized (provider merges: HealthKit climbed + pedometer descended; pedometer-unavailable → climbed only, display unchanged). Cascade adds the Motion step (CMPedometer.queryPedometerData triggers the permission dialog — sequence it). Detail/checklist: "7 STAIRCASES UP · 2 DOWN" when descended present.
- **Year picker timezone:** offered years computed with each report's own timezone (match ReportFilter.matches semantics).
- **Filter pill pluralization:** replace the inflect markup with explicit singular/plural strings (deterministic, no LocalizedStringKey trap); visual behavior covered by an assertion if a UI test touches it.
- **iPad scene rebinding:** PrivacyCoverWindow — rebind to the foreground-active scene on each show() instead of caching scenes.first; comment why (future multi-scene).
- Wrap: full suites; completion note here; update README features list (widgets, Control Center, digest, stairs down).

Verify: build, kit suite, UI suite. Commit `feat: flights descended + backlog sweep` → push.

### Task 5: Medications capture (device-verification-gated)

**Files:** `App/Sources/Providers/HealthProviders.swift` (or a dedicated MedicationsProvider), `Sources/DispatchKit/Capture/SensorSettings.swift` (re-enable the kind), `App/Sources/Settings/SensorSettingsView.swift` (explicit access-request row), project.yml purpose strings if the SDK requires one.

**Contract:**
- **Empirical SDK research FIRST** (session rule — this exact type crashed a device once): inspect the iOS 26 HealthKit SDK headers for the medication APIs (`HKUserAnnotatedMedication`, medication dose event types) and their authorization requirements — specifically whether they require per-object read authorization (`requestPerObjectReadAuthorization`, as vision prescriptions do) rather than bulk `requestAuthorization`. Quote the relevant header/doc lines in the report. The medication type must NEVER re-enter the bulk read set (comment the exclusion where the read-types set is built, referencing the original crash).
- Provider: captures the report day's medication dose events (name, dose description if exposed, taken/skipped, time) as readings (`medication.<n>` style additive strings). Authorization (user decision, second revision): NO separate opt-in — the header-verified medication authorization call runs as an additional SEQUENCED step inside the standard permission flow (`PermissionCascade.requestAll()` after the bulk HealthKit step, and the same path from Settings → "Request Sensor Access"), still as its own dedicated API call, NEVER by re-adding the type to the bulk read set. Authorization failure/denial degrades to `.unavailable`.
- Sensor toggle `healthMedications` DEFAULT ON like other health sensors. NOTE for the report: this places the medication auth call in fresh-install onboarding — the repo owner's device script MUST include the fresh-install onboarding crash-regression check before distributing to testers.
- Checklist row + detail rows render dose events; no data → unavailable.
- Test-gated as usual; kit tests for any pure mapping. **The definition of done for this task is suites-green + archive-clean, NOT feature-verified** — hardware verification is the repo owner's (sim has no medication data and can't reproduce the original crash). State this explicitly in the report with a device test script for the user (enable toggle → request access → grant in Health → file report → confirm readings; then the crash regression check: fresh install, onboarding cascade, confirm NO crash).

Verify: build, kit suite, UI suite, archive. Commit `feat: medications capture behind explicit access request` → push. Whole-branch review follows (controller-driven).

---

## Completion notes (Tasks 1–4, 2026-07-08)

- **T1 (03f9585):** WidgetSnapshot.compute + ReportStreak, DigestStats.compute + templateSummary (kit, pure, tested); tokens "N ANSWERS" switched to distinct-value count (IMG_3276 semantics), `.frequency` carries `distinctCount` uncapped by the top-20 list. Per the store-move amendment, no JSON file helpers were shipped.
- **T2 (5fe6185):** Store migrated into `group.io.robbie.Dispatch` (StoreLocation.migrate: main-store-first moves with rollback, legacy fallback, kit tests incl. rollback-on-failure). Empirically verified on simulator: marker row planted in a store at the legacy path survived the launch migration into the App Group container. DispatchWidgets extension (status widget: systemSmall/Medium + accessory circular/rectangular/inline; ControlWidget → StartReportControlIntent → OpenURLIntent `dispatch://report?trigger=control`). App Group entitlement archive-proven on BOTH targets (codesign dumps; aps-environment intact). Deep links via new `dispatch://` scheme (`.widget`/`.control` triggers). Reload pokes: report save (survey + quick answer), replan (+ next-prompt date published to shared defaults), foreground.
- **T3 (32ee044):** WeeklyDigestView (Settings entry + notification-tap sheet), DigestGenerator availability-switch (`SystemLanguageModel.default.availability`): available → streamed stats-only narrative; unavailable/test/error → templateSummary. `digest` OSLog category logs the path decision + timing. Optional Sunday 19:00 notification (default OFF), identifier `digest-weekly`, removals join the prompt-/gprompt-/nag- batch. UI test exercises the template path under `--mock-sensors`.
- **T4:** flights descended via CMPedometer merged into the healthFlights capture (climbed-only degradation), Motion cascade step sequenced after HealthKit, `NSMotionUsageDescription` via INFOPLIST_KEY (verified in built Info.plist); checklist "N STAIRCASES UP · M DOWN"; year picker uses each report's own timezone; filter pill explicit pluralization; PrivacyCoverWindow rebinds to the current foreground scene on every show.
