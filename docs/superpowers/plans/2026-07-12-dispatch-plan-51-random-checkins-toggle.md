# Dispatch Plan 51: Disable the global random check-ins ("Prompt Groups only")

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the app's own global random check-ins ("What are you up to right now?") always fire — the FREQUENCY "Alerts per Day" stepper floors at 1, so they can never be fully turned off. A tester who only wants her Prompt Groups to notify her is annoyed by a random schedule "I can't see." Give the user a way to fully disable the global random check-ins so someone can rely on Prompt Groups only. The switch also doubles as the discoverability fix — it names the previously-invisible global schedule and says how it differs from Prompt Groups.

**Architecture:** one stored pref (`NotificationPrefs.randomCheckInsEnabled`, kit, **default TRUE**) gates the global random schedule at a single kit seam. `PromptPlanner.globalPlan(randomCheckInsEnabled:prefs:…)` is the new single source of truth: when the flag is false it plans with the distribution skipped (the documented `alertsPerDay: 0` → "materialize only scheduledTimes" path), so ZERO random global prompts are produced. `NotificationScheduler.plannedDates` (app) routes every plan window through `globalPlan`; because the whole global family (`dates`, past-global nag parents, global nag chains) flows from `plannedDates`, gating it there empties all of them with no other scheduler edits. Prompt groups are planned by the separate `groupPlans` path (timer, calendar, and the event-observer families: workout-end, visit/place/beacon arrival) and are untouched. The UI is a Toggle at the top of the FREQUENCY section in `NotificationSettingsView` with a one-line caption; when off, the alerts-per-day stepper and the DISTRIBUTION section hide (they only shape the random schedule).

**Tech Stack:** Swift Testing (kit), UserDefaults-backed `NotificationPrefs`, SwiftUI settings (Toggle + conditional sections), XCUITest.

## Design decisions (decide + log)

- **Gate the RANDOM schedule only, not explicit SCHEDULED times — decided + why:** the toggle is labeled "Random Check-ins" and the tester's complaint is specifically the forced random schedule (min-1 stepper). Explicit SCHEDULED times (`prefs.scheduledTimes`, the "Add a Notification Time…" list) are opt-in and empty by default — the tester has none. Turning off "Random Check-ins" should NOT silently kill a fixed-time reminder a user deliberately added, so the gate skips only the distribution (`alertsPerDay → 0`) while `scheduledTimes` still materialize. For the tester (no scheduled times) the global count is 0 → Prompt Groups only, exactly the desired end state. REJECTED: gating the entire global family (random + scheduled). It would make the caption's "only get your Prompt Groups" literally true for everyone but is a silent regression for anyone who set a fixed time, and it contradicts the "Random" label. Users who want a fixed-time-only schedule already have `dailyAt` Prompt Groups. (Deviation from the task brief, which enumerated the hide-list as "Alerts-per-Day / Distribution / quiet-hours" — SCHEDULED was deliberately excluded here for that reason; there is no separate "quiet-hours" control on this screen, the SLEEP section is the nearest analog and is orthogonal.)
- **Default TRUE, migration-safe — the load-bearing decision:** `UserDefaults.bool(forKey:)` returns `false` for an ABSENT key. A naive getter would therefore SILENTLY disable the randoms of every existing user (who has never written the key) on upgrade — the exact failure the brief warns against. So the getter detects absence explicitly (`defaults.object(forKey: "randomCheckInsEnabled") == nil ⇒ true`) and only an explicit stored `false` (the user flipping the switch) disables randoms. No migration pass, no marker key needed — absence *is* "on." Kit-tested (`randomCheckInsDefaultsToTrueWhenKeyAbsent`).
- **Single gate seam in the kit, not scattered in the scheduler:** the gate lives in `PromptPlanner.globalPlan` so it's pure, deterministic, and unit-testable via `swift test` without constructing the `@MainActor` scheduler or touching `UNUserNotificationCenter`. The scheduler simply calls it; the test exercises the same production function the scheduler does.
- **Groups are never gated:** `groupPlans` (timer + calendar + event observers) has no dependency on `randomCheckInsEnabled`; the test asserts `GroupPlanner.plan` is identical with the flag on or off, proving "rely on Prompt Groups only" holds.
- **Mac is unaffected:** the Mac target deliberately schedules no notifications (plan 36 non-goal — no `NotificationScheduler`, no frequency UI), so there is no Mac surface to change. The Mac build is still verified because it links the kit (the new pref must compile there).

## Observable Acceptance Criteria

- Settings → Notifications, FREQUENCY section, shows a **Random Check-ins** switch (`random-checkins-toggle`) at the top, **ON by default**, above the Alerts per Day stepper.
- A caption under FREQUENCY (`random-checkins-caption`) reads **"Random prompts a few times a day. Turn off to only get your Prompt Groups."** when on, and **"Off — only your Prompt Groups (and any Scheduled times below) will notify you."** when off.
- With the switch **ON**: the **Alerts per Day** stepper (`alerts-per-day-count`) and the **DISTRIBUTION** rows (`distribution-…`) are visible — current behavior, unchanged.
- Turning the switch **OFF** hides the Alerts per Day stepper and the DISTRIBUTION section; the **SCHEDULED** section stays visible (explicit fixed times are unaffected). Turning it back on restores them.
- With the switch OFF, the app plans **zero** global random prompts: the Notifications hero (`next-notification-time`) shows no `FROM DISTRIBUTION` prompt, while any enabled Prompt Group's prompts still appear and its notifications still fire.
- An existing user upgrading (no stored value) keeps their random check-ins ON — no silent change.

## Global Constraints

- Kit change is the single gate seam; verified with `swift test` (exact counts). App target verified with `xcodebuild build`; UI target compiled with `build-for-testing` (local UI run blocked by the wedged `io.robbie.Dispatch` process — CI is the run gate).
- Additive persistence only: new key `randomCheckInsEnabled`, absence ⇒ true; no report/export schema change.
- Every existing behavior survives when the switch is left ON (the default): identical planning, nag chains, focus-filter interaction. Prompt Groups fire regardless of the switch.
- Frozen accessibility identifiers stay frozen (`alerts-per-day-count`, `distribution-*`, `next-notification-time`, …); new UI gets new identifiers (`random-checkins-toggle`, `random-checkins-caption`).
- Do NOT bump the build number. Scoped commit + PR; owner reviews (no merge / no auto-merge).

---

### Task 1: Kit pref + gate (test-first)

**Files:**
- Edit: `Sources/DispatchKit/Prompting/NotificationPrefs.swift` (add `randomCheckInsEnabled`)
- Edit: `Sources/DispatchKit/Prompting/PromptPlanner.swift` (add `globalPlan(randomCheckInsEnabled:…)`)
- Test: `Tests/DispatchKitTests/RandomCheckInsGateTests.swift`

**Interfaces:** `NotificationPrefs.randomCheckInsEnabled: Bool` (default true); `PromptPlanner.globalPlan(randomCheckInsEnabled:prefs:awakeStart:awakeEnd:seed:calendar:) -> [Date]`.

- [x] **Step 1:** Failing kit tests: default-true-when-absent, persists explicit false/true; `globalPlan` off ⇒ empty (and keeps scheduledTimes), on ⇒ exact count == legacy `plan(prefs:)`; `GroupPlanner.plan` non-empty and independent of the flag.
- [x] **Step 2:** Add the migration-safe pref (absence ⇒ true) and `globalPlan`. `swift test` green (824 tests, +7 new).

### Task 2: Scheduler gate

**Files:**
- Edit: `App/Sources/Notifications/NotificationScheduler.swift` (`plannedDates` routes through `globalPlan`)

- [x] **Step 1:** Replace the `PromptPlanner.plan(prefs:)` call in `plannedDates` with `PromptPlanner.globalPlan(randomCheckInsEnabled: prefs.randomCheckInsEnabled, …)`; document that gating here empties `dates`, past-global nag parents, and global nag chains while groups are planned separately. iOS build green.

### Task 3: Settings toggle

**Files:**
- Edit: `App/Sources/Settings/NotificationSettingsView.swift` (toggle + caption at top of FREQUENCY; hide stepper + DISTRIBUTION when off)

- [x] **Step 1:** `@State randomCheckInsEnabled` seeded from `prefs`; Toggle (`random-checkins-toggle`) + state-dependent caption (`random-checkins-caption`); gate the alerts-per-day row and `distributionSection` on the flag; `updateRandomCheckInsEnabled` persists + replans.
- [x] **Step 2:** UI test `testRandomCheckInsToggleHidesFrequencyControls` (default on; off hides stepper + distribution; back on restores). `build-for-testing` green.

## Completion note

**Shipped 2026-07-12** on branch `dispatch-plan-51-random-checkins-toggle` (spec + impl one PR; owner reviews, no auto-merge). Build number NOT bumped. Verification: `swift test` = 824 passed (7 new in `RandomCheckInsGateTests`); `DispatchApp` (iOS Simulator) and `DispatchMac` (macOS) both `BUILD SUCCEEDED`; `DispatchApp` `build-for-testing` `TEST BUILD SUCCEEDED` (UI test compiles; local UI run blocked by the wedged Mac process, CI is the run gate). Mac notification/settings surface unaffected (plan-36 non-goal — Mac schedules no notifications).
