# Dispatch Plan 39: Automatic AWAKE/ASLEEP state from sleep signals

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the AWAKE/ASLEEP state (today a purely manual pill/intent toggle) learns to set itself from two signals — (1) real-time: an opt-in "This Focus means I'm asleep" flag on the existing plan-15 Focus Filter, so activating Sleep Focus marks Dispatch asleep and deactivating it marks awake; (2) authoritative after-the-fact: HealthKit sleepAnalysis background delivery corrects the state when actual sleep data lands (flip awake after a sleep period visibly ended; flip asleep for an unambiguous in-progress period) and records the real sleep window. Manual toggles always win for a cooldown window. The whole feature is behind one Settings toggle, default OFF.

**Architecture:** decision logic is a pure kit state machine (`AwakeAutoPolicy` in `Sources/DispatchKit/UIState/`) — inputs are signal events + manual events + the clock, output is a transition-or-ignore decision with a reason; fully unit-tested including conflicting-signal sequences. `AwakeStore` grows additive source/timestamp tracking so the policy can enforce manual precedence. `FocusFilterState` (kit) gains an additive optional `indicatesSleep` field; `DispatchFocusFilter` (app intent, plan 15) gains the matching `@Parameter` and feeds signal 1 through the same in-app hook pattern as `replanInApp` — perform() already runs in the app process on background launch, so it can reach the live `AwakeStore` and trigger a replan with no new IPC. Signal 2 is a new app-side `SleepObserver` (`App/Sources/Providers/`), modeled line-for-line on `WorkoutEndObserver`: HKObserverQuery + `enableBackgroundDelivery`, last-seen marker in defaults, entirely test-gated. Wiring, background-delivery registration, the Settings toggle, and the notification-hero empty-state line live in the app target.

**Tech Stack:** Swift Testing (kit), AppIntents (SetFocusFilterIntent parameter), HealthKit (HKObserverQuery, HKCategoryType(.sleepAnalysis), enableBackgroundDelivery — entitlement `com.apple.developer.healthkit.background-delivery` already present and archive-proven), UserDefaults persistence, SwiftUI settings, os.Logger, XCUITest.

## Design decisions (decide + log)

- **Two signals, two jobs — strong forum evidence, officially undocumented (2026-07-10 research; Task 0 measures it):** HealthKit almost certainly cannot provide a real-time sleep-onset signal for Apple Watch native tracking. The API *accepts* sleepAnalysis background delivery at any frequency on iOS (Apple Developer Forums thread 650330), but delivery only fires when samples reach the phone's HealthKit store, and the watch writes/syncs its sleep samples during/after the night — samples reportedly arrive minutes-or-longer AFTER wake (forums thread 763329 — the right scenario, iOS app observing watch-written data, but FORUM-grade evidence, not Apple documentation; thread 781261 on observer reliability; background delivery is unavailable on watchOS entirely). Apple's own `enableBackgroundDelivery(for:frequency:withCompletion:)` doc adds that on iOS most types are capped at hourly wake-ups regardless of the requested frequency, and documents nothing about sleepAnalysis arrival timing. Therefore, BY DESIGN: **Signal 1 (Sleep Focus filter) is the only real-time path for both onset and wake** — the primary signal in both directions; **Signal 2 (HealthKit) is scoped to morning-authoritative correction + lagged wake detection** ("minutes-scale lag, best effort") and to recording the true sleep window. Because the load-bearing timing claim is forum-grade, **Task 0 runs a one-night on-device spike that measures actual sample-arrival timing on current watchOS before any Signal-2 code is written**, and the wake-lag expectations in this plan get updated from that measurement. Future maintainers: do NOT attempt real-time onset via HealthKit without re-running that measurement.
- **Signal 1 shape — one new Focus Filter parameter, off by default:** `@Parameter(title: "This Focus Means I'm Asleep", default: false) var indicatesSleep: Bool` on `DispatchFocusFilter`. The user attaches Dispatch's filter to their Sleep Focus in iOS Settings and flips this one switch (Apple provides no in-app enrollment — same setup path as plan 15, documented in the Settings footer). Activation delivery with the flag ⇒ asleep event; the deactivation delivery is all-defaults by Apple's documented lifecycle (flag resets to false), so "sleep focus ended" is detected from the PREVIOUS persisted state's `indicatesSleep`, read before the clear — never from the delivered instance.
- **`FocusFilterState.indicatesSleep` is additive and lenient:** `public var indicatesSleep: Bool?` (optional, omitted when nil/false semantics via `Bool? ?? false` at read sites). Old persisted blobs and any process still running old code decode unchanged — the plan-15 fail-open contract (corrupt blob ⇒ no filter) is untouched. `DispatchFocusFilter.state(from:)`'s `isConfigured` gains `|| intent.indicatesSleep` so a filter configured ONLY as a sleep marker (no name, no groups) still writes state on activation.
- **All state-clear paths emit the wake signal, not just the intent path:** `NotificationScheduler.activeFocusFilter`'s liveness gate (stale blob cleared when INFocusStatusCenter says no Focus is active) can be the first place a missed deactivation is noticed. Both the intent's clear path and the liveness-gate clear check the outgoing state's `indicatesSleep` and route a wake event through the policy. Signal ordering contract: apply the awake-state change BEFORE the replan runs, so the replan sees the new state (mirrors the existing `filterClearedInApp`-before-`replanInApp` ordering).
- **Signal 2 shape — `SleepObserver`, the `WorkoutEndObserver` pattern verbatim:** HKObserverQuery on `HKCategoryType(.sleepAnalysis)` + `enableBackgroundDelivery(frequency: .immediate)` (requesting .immediate is correct even though iOS may coalesce to hourly — the design tolerates arbitrary lag). Last-seen marker `sleepAuto.lastSeenEndDate` in app defaults, baselined to now on first start (no event storm from historical sleep data). Registered at LAUNCH in `DispatchApp.init` (HealthKit background delivery relaunches a terminated app headless — the workout observer comment applies verbatim), refreshed on settings-toggle changes; `refresh()` starts only when the auto toggle is ON, stops (and disables background delivery) otherwise.
- **Signal 2 event derivation (asleep-stage samples only, `allAsleepValues` — inBed is ignored):** on observer fire, fetch sleepAnalysis samples with endDate > lastSeen. **Wake:** the latest asleep-stage sample's endDate is within the recency window (12h — sized from the Task 0 measurement below; the batch arrives ≈4h post-wake and can land the same afternoon, so it is DECOUPLED from the 90 min cooldown the pre-measurement draft matched it to) AND no asleep-stage sample covers `now` ⇒ `healthSleepEnded(at: endDate)`. **Sleep onset (rare in practice — see decision 1; realistic only for sources that write live, e.g. some third-party apps/beds):** an asleep-stage sample STARTED within the recency window and is still open-ended/covers now ⇒ `healthSleepStarted(at: startDate)`. Anything older than the window is history, not a signal — it only updates the recorded window. Ambiguity resolves to no-op: the policy's default answer is "ignore", and the authoritative correction just waits for the next delivery.
- **Recorded sleep window for wake-report context:** on each fire the observer also computes the night's window (earliest asleep-stage startDate → latest endDate among samples intersecting the last 18h — the `sleepSeconds(sinceYesterdayEvening:)` lookback) and persists it as `sleepAuto.lastSleepWindowStart`/`End` doubles in app defaults. v1 consumers: the os_log line and the hero caption's honesty; the wake-report survey can surface it in a later plan. No report-schema change in this plan.
- **Precedence — manual wins for a 90-minute cooldown:** any manual change (home pill, `ToggleAwakeIntent`, future watch toggle — everything that calls `AwakeStore.toggle()`/`setAwake(source: .manual)`) stamps `lastManualChangeAt`. `AwakeAutoPolicy` ignores EVERY automatic event within 90 minutes of that stamp, regardless of direction. Why 90: long enough that "I flipped the pill because tonight is weird" survives Sleep Focus's scheduled activation and a straggling HealthKit delivery; short enough that automation recovers the same night. It's a named constant (`AwakeAutoPolicy.manualCooldown`), kit-tested, documented at the declaration.
- **Automatic transitions never present a survey.** The manual toggle's contract (flip returns a `ReportKind`, survey offered, state authoritative even if cancelled) is untouched — but auto transitions happen in background launches where no UI exists, and waking up to an ambush survey is wrong anyway. Auto transitions: set state, replan, os_log (`category: "awake-auto"`, one line per decision including ignores at debug level). The existing wake/sleep report kinds remain reachable exactly as today: via the pill.
- **`AwakeStore` grows additive source tracking, no behavior change to existing callers:** `setAwake(_:source:now:)` writing `awake.lastChangeSource` (`manual`/`focusFilter`/`health` raw strings) and `awake.lastManualChangeAt` (manual only); `toggle()` becomes a thin wrapper that records `.manual`. `isAwake`'s plain setter keeps working (used by tests/previews) and records nothing — call sites that should stamp a source are migrated in this plan.
- **Settings home: Notifications, not Sensors — decided + why:** the awake state exists to gate the prompt schedule (the replan's quiet-hours guard), the hero empty-state already explains "YOU'RE MARKED ASLEEP" there, and the Focus-filter status row (plan 15) — this feature's sibling — already lives there. Sensors settings is about what a REPORT captures; this feature captures nothing. New SLEEP section in `NotificationSettingsView` between the focus-filter and frequency sections: toggle **"Set automatically from Sleep Focus & Health"**, default OFF, stored as `NotificationPrefs.autoSleepEnabled` (defaults-backed like `digestEnabled`), with a footer explaining both signals and the Sleep Focus setup path.
- **Hero empty-state honesty:** when asleep AND `lastChangeSource != manual`, the caption becomes `"SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"` (or `"HEALTH DATA MARKED YOU ASLEEP — …"` for `.health`); the manual caption stays byte-identical (`"YOU'RE MARKED ASLEEP — PROMPTS RESUME AT WAKE"`). One switch in `emptyNextAlertState()`; no identifier changes.
- **Diagnostics:** os_log is the system of record (`Logger(subsystem: "io.robbie.Dispatch", category: "awake-auto")`). OPTIONAL integration: if plan 37's sync-diagnostics ring buffer (issue #23, "Sync conflict and diagnostics screen") has landed by execution time, mirror each auto transition into it with the same reason string; if not, skip — do NOT block on plan 37 or grow a bespoke buffer here.
- **Permissions/entitlements: zero new dialogs, zero profile work.** `sleepAnalysis` is already in `HealthKitReader.readTypes` (the bulk read set users authorize in the cascade), and `com.apple.developer.healthkit.background-delivery` is ALREADY in `App/Dispatch.entitlements` — `WorkoutEndObserver.swift` is the shipping precedent for `enableBackgroundDelivery(frequency: .immediate)` and the registration pattern to follow, so no new entitlement and no provisioning-profile recreation (the release-pipeline profiles only need recreating for NEW entitlements). The observer starts regardless of authorization state — HealthKit surfaces denial as queries returning nothing, and `authorizationStatus(for:)` is unreliable for read types by design. No PermissionCascade change, no top-up step.
- **Test gating absolute (standing rule):** `--mock-sensors`/`--ui-testing` ⇒ `SleepObserver` never touches HealthKit (internal gate like `WorkoutEndObserver`), the focus-filter path stays deterministic via the existing isolated-suite + `FOCUS_FILTER_STATE` injection hook, and the new UI test drives state via launch arguments only.

## Observable Acceptance Criteria

*(Appended 2026-07-11 with the implementation — the plan predates the plan-conventions requirement.)*

- Settings → Notifications shows a **SLEEP** section between the Focus-filter status row and FREQUENCY with the toggle **"Set automatically from Sleep Focus & Health"** (`auto-sleep-toggle`), OFF by default, and a footer naming both signals, the Focus Filters setup path, and the 90-minute manual override.
- With the toggle untouched, nothing anywhere changes: the Home pill (`awake-toggle`) keeps its exact manual semantics (flip → survey offer → state authoritative even if cancelled).
- iOS Settings → Focus → Sleep → Focus Filters → Dispatch shows the new **"This Focus Means I'm Asleep"** switch; a filter with it set shows **", marks asleep"** in its subtitle.
- With the toggle ON and that filter attached to Sleep Focus: engaging Sleep Focus flips Dispatch to ASLEEP within about a minute **without opening the app** (the pill reads ASLEEP on next launch); disengaging it flips AWAKE the same way.
- While asleep from an automatic source, the Notifications hero (`next-notification-source`) reads **"SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"** (or **"HEALTH DATA MARKED YOU ASLEEP — …"**); a manually-set asleep state keeps the byte-identical **"YOU'RE MARKED ASLEEP — PROMPTS RESUME AT WAKE"**.
- A manual pill flip within 90 minutes of an automatic signal wins: the state visibly stays where the user put it (automation ignores are debug-log-only).
- If the watch's sleep data arrives hours after wake while the state is already awake, nothing visibly changes (correct no-op); if the state was stranded asleep, it flips AWAKE when the batch lands.
- Sync Diagnostics' timeline shows one **awakeAuto** entry per automatic transition with the same reason string the `awake-auto` os_log line carries.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate).
- Additive persistence only: `FocusFilterState.indicatesSleep` optional and lenient (old blobs decode); new defaults keys namespaced (`awake.*`, `sleepAuto.*`); NO report/export schema change anywhere in this plan.
- Every existing behavior survives: the manual pill/intent toggle semantics (replan + survey offer, authoritative-if-cancelled), plan-15 filter plan semantics, the asleep replan guard, snooze-clearing while asleep. Default-OFF means a user who never opens the toggle sees ZERO behavior change.
- Frozen accessibility identifiers stay frozen (`awake-toggle`, `next-notification-time`, `next-notification-source`, `focus-filter-status`, …); new UI gets new identifiers (`auto-sleep-toggle`).
- Platform-timing claims above are FORUM-grade (forums 650330/763329/781261 + the enableBackgroundDelivery doc) — Task 0's on-device measurement is the authority; cite BOTH the sources and the measured result in code comments. Any NEW uncertain claim met during implementation is verified against docs and the finding recorded in a comment (plan 26 convention).
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing. Do NOT bump the build number.
- Track on GitHub Project 1: set the plan's issue to In Progress at dispatch, close with the build number when shipped.

---

### Task 0: Empirical spike — measure sleepAnalysis background-delivery timing on device

The forum-grade timing claim in decision 1 is load-bearing for Signal 2's whole design, so it gets MEASURED before Signal-2 code is written. Runs in parallel with Tasks 1–3 (which don't depend on the result); Task 4 consumes the findings.

**Files:**
- Modify: `App/Sources/DispatchApp.swift` (debug-flag-gated probe only — no product code)

- [x] **Step 1: Probe.** Behind a `--probe-sleep-delivery` launch argument AND a `sleepProbe.enabled` defaults flag (so it survives background relaunches, where launch args are absent — set the flag when the argument is seen, honor the flag thereafter), register an `HKObserverQuery` on `HKCategoryType(.sleepAnalysis)` + `enableBackgroundDelivery(frequency: .immediate)` at launch, following `WorkoutEndObserver.swift`'s registration pattern verbatim (entitlement already present — see the permissions decision). On EVERY observer fire, os_log (`category: "sleep-probe"`) a timestamped line: fire time, plus for each sleepAnalysis sample with endDate in the last 12h its stage raw value, startDate, endDate, and sourceRevision.source.name. Call the completion handler on every path.
- [x] **Step 2: One-night run (owner).** Robbie installs a dev build with the flag set on his device, sleeps normally with the watch on, and in the morning pulls the log (`log show --predicate 'category == "sleep-probe"'` or Console). The morning log definitively characterizes on current watchOS/iOS: (a) whether any fires occur DURING the night, (b) when the night's samples first arrive relative to actual wake, (c) whether they arrive as one batch or trickle.
- [x] **Step 3: Record + adjust.** Append the measured timings to this plan (spike-findings subsection) and update decision 1's wake-lag expectation and Task 4's recency-window reasoning from measurement. If the measurement CONTRADICTS the forum claim (e.g. mid-night deliveries are real), revisit whether Signal 2 can carry more of the onset job — as a logged design-decision amendment, not silent scope growth.
- [x] **Step 4: Keep or strip.** ~~Keep the probe permanently behind its flag (the `--dump-pending`/`--probe-focus-filter` precedent) — it's the re-measurement tool the design log tells future maintainers to run.~~ **AMENDED 2026-07-11 (owner decision, Robbie): STRIP the probe entirely as part of the plan-39 implementation.** Rationale: the measured findings below are the re-measurement baseline; the probe (unlike the launch-arg-only `--dump-pending`/`--probe-focus-filter` precedents) carried real UI surface (a Settings > Sensors Diagnostics toggle) plus an app-documents log file, and it can be resurrected verbatim from git history (commit `da42acf`, "feat: sleep-delivery probe (plan 39 Task 0 diagnostic)") if the measurement ever needs re-running. Removing it also lifts the "builds 22–29 not App-Store-submittable" restriction the probe imposed. Removed: `App/Sources/Providers/SleepDeliveryProbe.swift`, `AppTests/SleepProbeLogFormatterTests.swift`, and every wiring site carrying the `PLAN-39 TASK 0 PROBE` banner (DispatchApp.swift, SensorSettingsView.swift's Diagnostics section, project.yml's DispatchAppTests source entry). Plan 37's `--probe-cloudkit-events` harness is unrelated and stays.

### Task 0 spike findings (MEASURED 2026-07-10/11, two nights, iPhone + Apple Watch on current OS 26)

Probe log: `sleep-probe.log` (Settings > Sensors > Diagnostics toggle build; owner device, America/New_York). Summary of the raw log Robbie pulled 2026-07-11:

- **(a) Fires DO occur during the night with no user interaction** — genuine `appState=background`/`inactive` observer fires at 00:45Z, 02:03Z, and 06:07–06:12Z. The delivery MECHANISM works; forum claim 650330 (registration accepted) confirmed, and the ~hourly-wake cap is roughly consistent with observed fire spacing.
- **(b) But the night's samples are NOT in those fires.** Every overnight fire still carried only the PREVIOUS night's samples (`samples(24h)=19`, unchanged). Night 2's sleep (06:16Z–12:27Z, wake ≈08:27 ET) first appeared in a fire at **16:24Z — ≈3h56m after wake** (`samples(24h)=28`, appState=background). Night 1's first appearance lagged ≥8.5h, but that datum is contaminated (probe enabled that afternoon; min observed lag 8h36m is an upper-bound artifact). The bottleneck is watch→phone sample sync, not delivery notification: HealthKit fires promptly on ARRIVAL, and arrival is hours late.
- **(c) Arrival is one batch** — the full night (28 samples incl. core/deep/REM/awake stages, source "Robert's Apple Watch") landed in a single fire, not a trickle.

**Consequences (confirming decision 1, tightening the numbers):**
- Signal 2's honest label upgrades from "minutes-scale lag, best effort" to **"HOURS-scale lag (measured ≈4h post-wake on night 2); retrospective only."** HealthKit is authoritative for the true sleep WINDOW (stage-level detail is excellent once it arrives) and useless for live wake detection. Task 4's recency window must accept a same-day-afternoon arrival as "fresh."
- **Signal 1 (Sleep Focus filter) carries BOTH onset and wake in real time, alone.** Do not revisit HealthKit for onset/wake without re-running this measurement (this section is the re-measurement baseline).
- The forum-grade claim (763329) understated the lag: "minutes-or-longer after wake" measured as ~4 hours on a typical night.

### Task 1: Kit — FocusFilterState.indicatesSleep + AwakeStore source tracking

**Files:**
- Modify: `Sources/DispatchKit/Prompting/FocusFilterState.swift`, `Sources/DispatchKit/UIState/AwakeStore.swift`
- Test: extend `Tests/DispatchKitTests/FocusFilterStateTests.swift`, `Tests/DispatchKitTests/UIStateTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `FocusFilterState.indicatesSleep: Bool?` (init gains `indicatesSleep: Bool? = nil`)
- `AwakeChangeSource: String` enum — `.manual, .focusFilter, .health`
- `AwakeStore.setAwake(_:source:now:)`, `AwakeStore.lastChangeSource: AwakeChangeSource?`, `AwakeStore.lastManualChangeAt: Date?`

- [x] **Step 1: Write the failing tests.** `FocusFilterStateTests`: (a) round-trip with `indicatesSleep: true` preserves it; (b) LENIENCY — a JSON blob WITHOUT the key (verbatim old-format fixture string, not re-encoded) decodes with `indicatesSleep == nil`; (c) `filterPlan` output is unaffected by the flag. `UIStateTests`: (d) `setAwake(false, source: .focusFilter)` flips state, records source, does NOT stamp `lastManualChangeAt`; (e) `toggle()` records `.manual` and stamps `lastManualChangeAt`; (f) persistence — a second `AwakeStore` on the same suite reads back source + timestamp; (g) the plain `isAwake` setter records no source (existing-caller safety).
- [x] **Step 2: Run `swift test` — expect the new tests FAIL** (members don't exist).
- [x] **Step 3: Implement.** `FocusFilterState`: add the optional field + init parameter (Codable synthesis handles absence). `AwakeStore`:

```swift
/// Who last changed the awake state — the automation policy (plan 39)
/// needs to know whether the standing state is a user decision.
public enum AwakeChangeSource: String, Sendable {
    case manual, focusFilter, health
}

// inside AwakeStore
public private(set) var lastChangeSource: AwakeChangeSource? // backed by "awake.lastChangeSource"
public private(set) var lastManualChangeAt: Date?            // backed by "awake.lastManualChangeAt"

/// Source-stamping state change (plan 39). MANUAL changes stamp the
/// cooldown timestamp that outranks automation; automatic sources don't.
/// The plain `isAwake` setter stays source-less for existing callers.
public func setAwake(_ awake: Bool, source: AwakeChangeSource, now: Date = Date()) {
    isAwake = awake
    lastChangeSource = source
    defaults.set(source.rawValue, forKey: "awake.lastChangeSource")
    if source == .manual {
        lastManualChangeAt = now
        defaults.set(now.timeIntervalSince1970, forKey: "awake.lastManualChangeAt")
    }
}

@discardableResult
public func toggle(now: Date = Date()) -> ReportKind {
    let kind: ReportKind = isAwake ? .sleep : .wake
    setAwake(!isAwake, source: .manual, now: now)
    return kind
}
```

(init reads both keys back; `toggle()` keeps its exact signature compatibility — the added defaulted parameter breaks no caller.)
- [x] **Step 4: Run `swift test` — expect PASS** (whole kit suite).
- [x] **Step 5: Commit** — `git commit -m "feat(kit): focus-filter sleep flag + awake source tracking (plan 39)"` → push.

### Task 2: Kit — AwakeAutoPolicy state machine

**Files:**
- Create: `Sources/DispatchKit/UIState/AwakeAutoPolicy.swift`
- Test: create `Tests/DispatchKitTests/AwakeAutoPolicyTests.swift`

**Interfaces (produced):**
- `AwakeAutoPolicy.Event` — `.focusSleepActivated, .focusSleepDeactivated, .healthSleepEnded(at: Date), .healthSleepStarted(at: Date)`
- `AwakeAutoPolicy.Decision` — `.transition(toAwake: Bool, reason: String)` / `.ignore(reason: String)`
- `AwakeAutoPolicy.decide(event:isAwake:lastManualChangeAt:now:) -> Decision`
- `AwakeAutoPolicy.manualCooldown: TimeInterval` (90 × 60), `AwakeAutoPolicy.healthRecencyWindow: TimeInterval` (12 × 60 × 60 — hours-scale per Task 0, decoupled from the cooldown)

- [x] **Step 1: Write the failing tests** — table-driven over the full matrix, every case asserting BOTH the decision and the reason string prefix:
  - Focus activation while awake → transition asleep; while already asleep → ignore ("already asleep").
  - Focus deactivation while asleep → transition awake; while awake → ignore.
  - `healthSleepEnded` while asleep, endDate within `healthRecencyWindow` of now → transition awake; endDate older than the window → ignore ("stale sample"); while already awake → ignore.
  - `healthSleepStarted` while awake, recent → transition asleep; stale/already-asleep → ignore.
  - **Cooldown:** every one of the four events, fired < 90 min after `lastManualChangeAt`, → ignore ("manual cooldown"), in BOTH directions (manual-asleep suppresses focus-wake; manual-awake suppresses focus-sleep); at exactly 90 min + 1s → transitions resume. nil `lastManualChangeAt` → no cooldown.
  - **Conflicting-signal sequences (folded, not per-event):** (a) manual wake at 06:00, Sleep Focus still active re-fires activation at 06:10 → ignored; HealthKit reports sleep ended 06:05 delivered 07:45 → ignored (already awake) — state stays awake throughout. (b) Sleep Focus on at 22:00 (→ asleep), user manually flips awake at 23:00 (insomnia), Focus deactivation at 07:00 → ignore (already awake). (c) Focus deactivates 07:00 (→ awake), HealthKit delivers sleep-ended-06:52 at 07:20 → ignore (already awake, correct no-op). (d) NO Focus configured: healthSleepEnded at 07:30 while asleep → transition awake (health as sole, lagged wake path).
- [x] **Step 2: `swift test` — RED.**
- [x] **Step 3: Implement** — a single pure function, no stored state:

```swift
/// Decides whether an automation signal may change the AWAKE/ASLEEP state
/// (plan 39). Pure: callers own persistence and side effects. Signal roles
/// are asymmetric BY VERIFIED PLATFORM REALITY (see plan 39 design log —
/// forums 650330/763329/781261): the Sleep Focus filter is the only
/// real-time path; HealthKit events arrive minutes-or-longer late and act
/// as authoritative correction.
public enum AwakeAutoPolicy {
    /// Manual changes outrank automation for this long — long enough to
    /// survive Sleep Focus's scheduled flip and a straggling HealthKit
    /// delivery, short enough that automation recovers the same night.
    public static let manualCooldown: TimeInterval = 90 * 60
    /// HealthKit samples older than this are history, not a signal.
    public static let healthRecencyWindow: TimeInterval = 12 * 60 * 60

    public enum Event: Equatable, Sendable {
        case focusSleepActivated
        case focusSleepDeactivated
        case healthSleepEnded(at: Date)
        case healthSleepStarted(at: Date)
    }

    public enum Decision: Equatable, Sendable {
        case transition(toAwake: Bool, reason: String)
        case ignore(reason: String)
    }

    public static func decide(
        event: Event, isAwake: Bool, lastManualChangeAt: Date?, now: Date = Date()
    ) -> Decision {
        if let manual = lastManualChangeAt, now.timeIntervalSince(manual) < manualCooldown {
            return .ignore(reason: "manual cooldown (\(Int(now.timeIntervalSince(manual) / 60))m ago)")
        }
        switch event {
        case .focusSleepActivated:
            guard isAwake else { return .ignore(reason: "already asleep") }
            return .transition(toAwake: false, reason: "sleep focus activated")
        case .focusSleepDeactivated:
            guard !isAwake else { return .ignore(reason: "already awake") }
            return .transition(toAwake: true, reason: "sleep focus deactivated")
        case .healthSleepEnded(let endedAt):
            guard now.timeIntervalSince(endedAt) < healthRecencyWindow else {
                return .ignore(reason: "stale sample (ended \(Int(now.timeIntervalSince(endedAt) / 60))m ago)")
            }
            guard !isAwake else { return .ignore(reason: "already awake") }
            return .transition(toAwake: true, reason: "health sleep period ended")
        case .healthSleepStarted(let startedAt):
            guard now.timeIntervalSince(startedAt) < healthRecencyWindow else {
                return .ignore(reason: "stale sample (started \(Int(now.timeIntervalSince(startedAt) / 60))m ago)")
            }
            guard isAwake else { return .ignore(reason: "already asleep") }
            return .transition(toAwake: false, reason: "health sleep period started")
        }
    }
}
```

- [x] **Step 4: `swift test` — GREEN** (whole suite).
- [x] **Step 5: Commit** — `git commit -m "feat(kit): AwakeAutoPolicy — auto sleep-state machine (plan 39)"` → push.

### Task 3: App — Focus filter sleep parameter + signal-1 wiring

**Files:**
- Modify: `App/Sources/Intents/DispatchFocusFilter.swift`, `App/Sources/Notifications/NotificationScheduler.swift`, `App/Sources/DispatchApp.swift`

**Interfaces (produced):** `DispatchFocusFilter.awakeSignalInApp: (@MainActor (AwakeAutoPolicy.Event) -> Void)?` hook; `AwakeAutoController` (app, `App/Sources/Providers/AwakeAutoController.swift` — created here, shared with Task 4).

- [x] **Step 1: `AwakeAutoController`** — the one place decisions are applied (both signals route through it):

```swift
/// Applies AwakeAutoPolicy decisions (plan 39): the single funnel for both
/// automation signals. Gated on the Settings toggle; auto transitions never
/// present a survey (background launches have no UI, and the manual pill
/// remains the only survey-offering path).
@MainActor
final class AwakeAutoController {
    private let awakeStore: AwakeStore
    private let prefs: NotificationPrefs
    private let scheduler: NotificationScheduler

    init(awakeStore: AwakeStore, prefs: NotificationPrefs, scheduler: NotificationScheduler) { … }

    func handle(_ event: AwakeAutoPolicy.Event, now: Date = Date()) {
        guard prefs.autoSleepEnabled else { return }
        let decision = AwakeAutoPolicy.decide(
            event: event, isAwake: awakeStore.isAwake,
            lastManualChangeAt: awakeStore.lastManualChangeAt, now: now)
        switch decision {
        case .transition(let toAwake, let reason):
            awakeLog.info("auto transition → \(toAwake ? "awake" : "asleep"): \(reason, privacy: .public)")
            awakeStore.setAwake(toAwake, source: source(for: event), now: now)
            // Replan AFTER the state change so it sees the new state —
            // same ordering contract as filterClearedInApp/replanInApp.
            scheduler.replan(prefs: prefs, awakeStore: awakeStore)
            // OPTIONAL (plan 37): if the sync-diagnostics ring buffer has
            // landed, mirror this line into it here.
        case .ignore(let reason):
            awakeLog.debug("auto event \(String(describing: event), privacy: .public) ignored: \(reason, privacy: .public)")
        }
    }
}
```

`NotificationPrefs` gains `autoSleepEnabled: Bool` (defaults-backed, default false — the `digestEnabled` pattern; kit change, add a one-line kit test alongside the existing prefs tests).
- [x] **Step 2: Intent parameter + emission.** `DispatchFocusFilter` gains the parameter and, in `perform()`, emits through a hook (the `replanInApp` pattern — set in `DispatchApp.init`):

```swift
@Parameter(title: "This Focus Means I'm Asleep", default: false)
var indicatesSleep: Bool

@MainActor static var awakeSignalInApp: (@MainActor (AwakeAutoPolicy.Event) -> Void)?
```

In `perform()`: read `let previous = FocusFilterState.read(from: defaults)` BEFORE writing/clearing. On the write path with `indicatesSleep` → after writing state, `awakeSignalInApp?(.focusSleepActivated)` (before `replanInApp` — the replan must see asleep). On the clear path → if `previous?.indicatesSleep == true`, `awakeSignalInApp?(.focusSleepDeactivated)` before `filterClearedInApp`/`replanInApp`. `state(from:)`: `isConfigured` gains `|| intent.indicatesSleep`; the returned state carries `indicatesSleep: intent.indicatesSleep ? true : nil`. `displayRepresentation` appends ", marks asleep" when set.
- [x] **Step 3: Liveness-gate parity.** In `NotificationScheduler.activeFocusFilter`'s stale-clear branch: capture `state.indicatesSleep == true` before `FocusFilterState.clear`, and invoke a new `staleSleepFilterCleared: (() -> Void)?` hook (set by DispatchApp to `awakeAutoController.handle(.focusSleepDeactivated)`) after `focusFilterCleared()`. A missed deactivation can otherwise strand the state asleep until HealthKit's lagged correction.
- [x] **Step 4: Wire in `DispatchApp.init`** — construct `AwakeAutoController` after the scheduler, set `DispatchFocusFilter.awakeSignalInApp` next to the existing `replanInApp`/`filterClearedInApp` assignments, inject the controller into the environment for Settings. Extend the `--probe-focus-filter` harness: activation with `indicatesSleep = true` prints `FOCUS-PROBE-SLEEP: asleep=\(!awakeStore.isAwake)`, deactivation prints the wake flip — the same simulator-observable evidence trail plan 15 left.
- [x] **Step 5: Verify** — `swift test` (prefs + any kit deltas green), `xcodebuild build-for-testing`, run the probe on the simulator and paste the `FOCUS-PROBE-SLEEP` lines into the PR notes.
- [x] **Step 6: Commit** — `git commit -m "feat: sleep-focus filter parameter drives auto asleep state (plan 39)"` → push.

### Task 4: App — SleepObserver (HealthKit background delivery)

**Files:**
- Create: `App/Sources/Providers/SleepObserver.swift`
- Modify: `App/Sources/DispatchApp.swift`

- [x] **Step 1: Implement `SleepObserver`** — clone `WorkoutEndObserver`'s structure (same `UncheckedSendableBox` completion-handler discipline — the handler MUST be called on every path or HealthKit throttles delivery; same `isHandlingFire` serialization; same test gate):
  - `refresh()`: start when `prefs.autoSleepEnabled` && not test env && `HKHealthStore.isHealthDataAvailable()`; stop + `disableBackgroundDelivery` otherwise.
  - `start()`: baseline `sleepAuto.lastSeenEndDate` to now on first run; `HKObserverQuery(sampleType: HKCategoryType(.sleepAnalysis))`; `enableBackgroundDelivery(for: HKCategoryType(.sleepAnalysis), frequency: .immediate)` with the sourced comment: *iOS accepts any frequency for sleepAnalysis (forums 650330) but wakes at most ~hourly for most types (enableBackgroundDelivery doc); forum reports (763329) say watch-native samples arrive minutes-or-longer after wake, and the Task 0 one-night device measurement found: [MEASURED RESULT HERE] — this observer is the lagged/authoritative signal by design; real-time onset is the Focus filter's job (plan 39 design log).* Fill the bracket from Task 0's findings — this task must not start until they exist.
  - `handleObserverFire()`: fetch asleep-stage samples (filter via `HKCategoryValueSleepAnalysis.allAsleepValues`, the `sleepSeconds` precedent) with endDate > lastSeen, limit-bounded, sorted ascending; persist the new lastSeen BEFORE emitting (double-fire safety, the workout-observer comment applies). Derive at most one event per fire: newest sample covering now → `.healthSleepStarted(at: itsStartDate)`; else newest endDate within `AwakeAutoPolicy.healthRecencyWindow` → `.healthSleepEnded(at: newestEndDate)`; else no event. Hand it to `AwakeAutoController.handle(_:)` (recency/direction/cooldown arbitration lives in the POLICY, kit-tested — the observer only describes what it saw).
  - Record the sleep window: query asleep-stage samples over the last 18h, persist min startDate / max endDate as `sleepAuto.lastSleepWindowStart`/`End`, log it.
- [x] **Step 2: Launch + lifecycle wiring.** `DispatchApp.init`: construct after `AwakeAutoController`, call `sleepObserver.refresh()` next to `workoutEndObserver.refresh()` with the same headless-relaunch comment; `.environment(sleepObserver)`; refresh again in `onAppear` (parity with the other observers) and from the Settings toggle (Task 5).
- [x] **Step 3: Verify** — `xcodebuild build-for-testing`; on the simulator (Health app → add a sleep sample ending now, foreground Dispatch with the toggle ON) confirm the `awake-auto` os_log lines show the fire → decision → replan chain; record what was observable in the PR notes (simulator HealthKit background delivery is best-effort — the foreground fire is the honest sim-verifiable slice).
- [x] **Step 4: Commit** — `git commit -m "feat: sleepAnalysis background delivery corrects awake state (plan 39)"` → push.

### Task 5: App — Settings toggle + hero empty-state + UI test

**Files:**
- Modify: `App/Sources/Settings/NotificationSettingsView.swift`
- Test: create `AppUITests/AutoSleepUITests.swift`

- [x] **Step 1: Failing UI test** — launch with `--ui-testing --skip-onboarding`; navigate to Settings → Notifications; assert `auto-sleep-toggle` exists and is OFF by default; toggle it; relaunch-free assertion that it stays on (`.isSelected`/value). Second test: launch with the toggle pre-enabled via launch defaults + a launch argument `--auto-asleep` (test hook: sets `awakeStore.setAwake(false, source: .focusFilter)` in the test-env branch of DispatchApp.init) and assert `next-notification-source` reads `"SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"`. RED.
- [x] **Step 2: Implement the SLEEP section** (between `focusFilterSection` and `frequencySection`):

```swift
private var sleepSection: some View {
    Section {
        Toggle("Set automatically from Sleep Focus & Health", isOn: $autoSleepEnabled)
            .foregroundStyle(.white)
            .tint(.white.opacity(0.4))
            .accessibilityIdentifier("auto-sleep-toggle")
            .onChange(of: autoSleepEnabled) { _, enabled in
                prefs.autoSleepEnabled = enabled
                sleepObserver.refresh()   // arm/disarm background delivery now
                replan()
            }
            .listRowBackground(Color.white.opacity(0.12))
    } header: {
        sectionHeader("SLEEP")
    } footer: {
        Text("Marks you asleep when a Focus with Dispatch's filter set to \"This Focus Means I'm Asleep\" turns on (Settings → Focus → Sleep → Focus Filters → Dispatch), and corrects the state from Health sleep data after the fact. Your manual toggle always wins for 90 minutes.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
    }
}
```

- [x] **Step 3: Hero caption switch** in `emptyNextAlertState()`'s asleep branch:

```swift
} else {
    let caption = switch awakeStore.lastChangeSource {
    case .focusFilter: "SLEEP FOCUS MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"
    case .health: "HEALTH DATA MARKED YOU ASLEEP — PROMPTS RESUME AT WAKE"
    case .manual, nil: "YOU'RE MARKED ASLEEP — PROMPTS RESUME AT WAKE"
    }
    return .empty(title: "No prompts scheduled", caption: caption)
}
```

- [x] **Step 4: Verify** — build; `AutoSleepUITests` GREEN; re-run the hero's existing sentinel suites (`NavigationUITests`, `FocusFilterUITests` — the settings screen gained a section, identifiers unchanged).
- [x] **Step 5: Commit** — `git commit -m "feat: auto sleep-state settings toggle + honest hero captions (plan 39)"` → push.

### Task 6: Merge gate + self-review

- [ ] **Merge gate:** `swift test` (full kit), `xcodebuild build-for-testing`, FULL UI suite. Default-OFF regression sweep: with the toggle untouched, `NavigationUITests.testNavigationAndAwakeToggle` (manual pill semantics byte-identical) and the plan-15 `FocusFilterUITests` must pass unmodified. *(Runs at the gate; locally verified: full kit suite 653 green, build-for-testing clean, AutoSleepUITests + NavigationUITests + FocusFilterUITests + NotificationSettingsUITests + DigestScheduleUITests green on iPhone 17 Pro.)*
- [x] Grep the diff for accidental changes to frozen identifiers and to `FocusFilterState`'s existing JSON keys (`git diff main | grep -E 'accessibilityIdentifier|CodingKeys'`).
- [x] Confirm the sourced comments cite forums 650330/763329/781261, the enableBackgroundDelivery doc, AND Task 0's measured result at: the SleepObserver frequency call, the AwakeAutoPolicy header, and the design-log warning against re-attempting real-time HealthKit onset without re-measuring. Confirm the Task 0 spike-findings subsection was appended to this plan.
- [x] Confirm zero diffs to report schema/export (`Sources/DispatchKit/V2/`, `Export/`) and zero new permission-cascade steps.
- [x] Re-read the conflicting-signal test table against the implementation one final time — every `ignore` reason string must match what the controller logs, so a field os_log trace can be diffed against the kit tests.
- [x] Update this plan's checkboxes + append the implementation report section (plan 26/29 convention), noting what the simulator could and couldn't prove about background delivery, and whether the plan-37 ring-buffer mirror was included.

## Implementation report (2026-07-11)

Implemented on `plan-39-doc` (the one-branch workflow — PR #42 becomes the feature PR), rebased onto post-test-suite-restructure main (8135926) before app-side work so `SleepObserver` was written against the `WorkoutEndMarkerPlanner`-era `WorkoutEndObserver`.

- **Task 0 Step 4 amendment executed:** the probe was STRIPPED (owner decision, recorded above) — files, Settings toggle, project.yml entry, all `PLAN-39 TASK 0 PROBE` banners. Resurrectable from commit `da42acf`. This lifts the builds-22–29 App-Store-submittability restriction.
- **Kit:** `FocusFilterState.indicatesSleep` (lenient old-blob decode pinned by a verbatim-fixture test), `AwakeChangeSource` + `AwakeStore.setAwake(_:source:now:)`/`lastChangeSource`/`lastManualChangeAt`, `AwakeAutoPolicy` exactly as specced (25 new kit tests incl. the four conflicting-signal sequences and both-direction cooldown). `NotificationPrefs.autoSleepEnabled` (default OFF). Kit suite: 653 green.
- **App:** `AwakeAutoController` (single funnel, toggle-gated, no survey, replan-after-state-change, plan-37 ring-buffer mirror INCLUDED — `kindRaw: "awakeAuto"` rides the buffer's unknown-kind leniency); `DispatchFocusFilter.indicatesSleep` + `awakeSignalInApp` hook with previous-state deactivation detection; `NotificationScheduler.staleSleepFilterCleared` liveness-gate parity; `SleepObserver` (WorkoutEndObserver discipline: completion-handler-on-every-path, persist-before-emit, isHandlingFire, launch+onAppear+toggle refresh); SLEEP settings section + source-honest hero captions; `--auto-asleep` test hook.
- **Deviations (all minor, reasons inline in code):**
  - `scheduler.authorizationStatus()` reports `.authorized` under the test environment — UI tests never grant permission (the replan-gate rationale), and the authorized empty states (the asleep captions) were otherwise unreachable in UI tests. No existing test asserted the unauthorized caption.
  - `NotificationSettingsUITests.testNagStepperRowsRespondToTaps` gained a scroll-into-view loop: the new SLEEP section pushed the nag rows below the fold (off-screen SwiftUI List rows aren't in the AX tree; the digest-suite precedent). No identifier changes.
  - The Task 5 toggle test asserts the flip holds relaunch-free (per the plan's own step wording) rather than a navigate-away-and-back round-trip, which trips over SwiftUI destination-value caching, not prefs persistence.
  - `AwakeAutoController` is `@Observable` so it can ride `.environment` as the plan's wiring step asks.
- **What the simulator could and couldn't prove:** the `--probe-focus-filter` harness printed the full Signal-1 chain (`FOCUS-PROBE-SLEEP: asleep=true source=focusFilter`, `FOCUS-PROBE-SLEEP-WAKE: awake=true source=focusFilter`). For Signal 2, the sim-verifiable slice was registration + fire handling (`awake-auto: sleep background delivery enabled: true`, plus a graceful auth-not-determined error fire with the completion handler still called); real batched watch-sample delivery is on-device-only by nature (Task 0 already measured it).
- **On-device verification owed (owner):** (1) Sleep Focus engage → asleep and disengage → awake while the app is backgrounded; (2) the morning HealthKit batch (~4h post-wake) correcting a stranded-asleep state and recording the window; (3) manual-pill precedence inside the 90-minute cooldown; (4) the awakeAuto rows appearing in Sync Diagnostics.
