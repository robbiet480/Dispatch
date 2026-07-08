# Dispatch Plan 4: Prompting Engine (timed notifications, interactive answers, App Intents)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dispatch prompts like the original: N alerts/day in Random / Semi-random / Regular distributions plus fixed scheduled times, delivered as interactive notifications (answer the first Yes/No question inline, or Snooze 15m, or tap through to the survey), with Shortcuts/Siri App Intents. Scheduling logic is a pure, seeded, fully tested function.

**Architecture:** DispatchKit gains `NotificationPrefs` (persisted settings) and `PromptPlanner` (pure `plan(...) -> [Date]`). The app gains `NotificationScheduler` (UNUserNotificationCenter: permission, request building, delegate routing, re-planning), notification settings UI, and App Intents. Event triggers (visits, workout-end, Focus Filter labels) are explicitly deferred to the backlog with widgets.

**Tech Stack:** UserNotifications, AppIntents, Swift Testing, existing SurveyFlowView/AwakeStore/ReportBuilder.

**Spec:** `docs/superpowers/specs/2026-07-07-reporter-clone-design.md` §5

## Global Constraints

- Planner is pure and deterministic: `PromptPlanner.plan(prefs:awakeStart:awakeEnd:seed:) -> [Date]` with a seeded RNG (`SystemRandomNumberGenerator` NEVER used in the planner).
- Distributions for N alerts in window W = awakeEnd−awakeStart: **random** = N independent uniform draws in W, sorted; **semiRandom** = W split into N equal slots, one uniform draw per slot; **regular** = awakeStart + W/N × k for k in 0..<N (skip index 0 if it equals awakeStart exactly? No — include; first alert at window start is fine). Fixed `scheduledTimes` (hour/minute) are appended for the same day, deduplicated to minute granularity, past-times-for-today excluded at scheduling (not planning) layer.
- Default awake window when no data: 08:00–24:00 local. When `AwakeStore.isAwake == false`, no prompts are scheduled until awake again.
- Notification category `DISPATCH_PROMPT` actions: up to two quick-answer actions (first enabled regular-kind Yes/No question's "Yes"/"No") + "Snooze 15m". Quick answers file a minimal report via `ReportBuilder.save` (kind .regular, trigger .notification, the one answered question, NO sensor capture — network/location work from a notification action is out of budget; document this). Snooze schedules a single follow-up notification +15 min. Tapping the notification body opens the app into a new regular survey (trigger .notification).
- Re-plan on: app foreground, prefs change, awake toggle. Plan horizon: today + tomorrow (re-planning on foreground keeps the horizon rolling). All pending DISPATCH_PROMPT requests are replaced on each re-plan (stable identifier prefix `prompt-`; snooze uses `snooze-` and is NOT cleared by re-plans).
- All new DispatchKit logic Swift-Testing-tested; suites (kit + UI) stay green; commit + push per green cycle. No sub-agent delegation by implementers.

---

### Task 1: DispatchKit — NotificationPrefs + PromptPlanner (pure, seeded)

**Files:**
- Create: `Sources/DispatchKit/Prompting/NotificationPrefs.swift`
- Create: `Sources/DispatchKit/Prompting/PromptPlanner.swift`
- Test: `Tests/DispatchKitTests/PromptPlannerTests.swift`

**Interfaces:**
- `enum PromptDistribution: String, Codable, CaseIterable, Sendable { case random, semiRandom, regular }` with `func description(alertsPerDay: Int) -> String` ("6 randomly timed alerts every 24 hours" / "1 random alert every 4 hours" / "1 alert every 4 hours" — computed from 24/alertsPerDay).
- `final class NotificationPrefs: @unchecked Sendable` (UserDefaults-backed, injectable suite): `alertsPerDay: Int` (default 4, clamped 1...12), `distribution: PromptDistribution` (default .semiRandom), `scheduledTimes: [DateComponents]` (hour+minute only, Codable via JSON in defaults, default []).
- `enum PromptPlanner { static func plan(prefs: NotificationPrefs, awakeStart: Date, awakeEnd: Date, seed: UInt64) -> [Date] }` — sorted ascending, distribution rules above, scheduledTimes materialized onto awakeStart's calendar day (report zone = current calendar), minute-deduplicated against the distribution output.
- Deterministic seeded generator: implement `struct SeededGenerator: RandomNumberGenerator` (SplitMix64: `state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31)`).

**Tests (write first, transcribe exactly):**

```swift
import Foundation
import Testing
@testable import DispatchKit

private func prefs(_ n: Int, _ d: PromptDistribution, times: [DateComponents] = []) -> NotificationPrefs {
    let p = NotificationPrefs(defaults: UserDefaults(suiteName: "np-\(UUID().uuidString)")!)
    p.alertsPerDay = n
    p.distribution = d
    p.scheduledTimes = times
    return p
}

private let dayStart = ISO8601DateFormatter().date(from: "2026-07-08T08:00:00Z")!
private let dayEnd = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")! // 16h window

@Test func planIsDeterministicForSameSeed() {
    let p = prefs(6, .random)
    let a = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 42)
    let b = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 42)
    let c = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 43)
    #expect(a == b)
    #expect(a != c)
}

@Test func randomProducesSortedTimesInsideWindow() {
    let dates = PromptPlanner.plan(prefs: prefs(6, .random), awakeStart: dayStart, awakeEnd: dayEnd, seed: 7)
    #expect(dates.count == 6)
    #expect(dates == dates.sorted())
    #expect(dates.allSatisfy { $0 >= dayStart && $0 < dayEnd })
}

@Test func semiRandomPutsOneAlertPerSlot() {
    let n = 4
    let dates = PromptPlanner.plan(prefs: prefs(n, .semiRandom), awakeStart: dayStart, awakeEnd: dayEnd, seed: 9)
    #expect(dates.count == n)
    let slot = dayEnd.timeIntervalSince(dayStart) / Double(n)
    for (index, date) in dates.enumerated() {
        let offset = date.timeIntervalSince(dayStart)
        #expect(offset >= slot * Double(index) && offset < slot * Double(index + 1))
    }
}

@Test func regularIsEvenlySpaced() {
    let dates = PromptPlanner.plan(prefs: prefs(4, .regular), awakeStart: dayStart, awakeEnd: dayEnd, seed: 1)
    #expect(dates.count == 4)
    let interval = dayEnd.timeIntervalSince(dayStart) / 4
    for (index, date) in dates.enumerated() {
        #expect(abs(date.timeIntervalSince(dayStart) - interval * Double(index)) < 1)
    }
}

@Test func scheduledTimesAppendAndDedupe() {
    var nine = DateComponents(); nine.hour = 9; nine.minute = 30
    let p = prefs(2, .regular, times: [nine])
    let dates = PromptPlanner.plan(prefs: p, awakeStart: dayStart, awakeEnd: dayEnd, seed: 1)
    #expect(dates.count == 3)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(dates.contains { calendar.component(.hour, from: $0) == 9 && calendar.component(.minute, from: $0) == 30 })
}

@Test func prefsClampAndPersist() {
    let defaults = UserDefaults(suiteName: "np-clamp-\(UUID().uuidString)")!
    let p = NotificationPrefs(defaults: defaults)
    #expect(p.alertsPerDay == 4)
    #expect(p.distribution == .semiRandom)
    p.alertsPerDay = 99
    #expect(p.alertsPerDay == 12)
    p.alertsPerDay = 0
    #expect(p.alertsPerDay == 1)
    p.distribution = .random
    #expect(NotificationPrefs(defaults: defaults).distribution == .random)
}

@Test func distributionDescriptions() {
    #expect(PromptDistribution.random.description(alertsPerDay: 6) == "6 randomly timed alerts every 24 hours")
    #expect(PromptDistribution.semiRandom.description(alertsPerDay: 6) == "1 random alert every 4 hours")
    #expect(PromptDistribution.regular.description(alertsPerDay: 6) == "1 alert every 4 hours")
}
```

Note for the planner's scheduledTimes materialization: use a GMT-pinned calendar when the awakeStart was constructed in GMT — i.e., materialize scheduled times using `Calendar.current` BUT the test pins its own calendar; to keep the test deterministic across machines, `PromptPlanner.plan` takes an optional `calendar: Calendar = .current` parameter and the test passes a GMT calendar. Adjust the test call accordingly (`plan(prefs:awakeStart:awakeEnd:seed:calendar:)`) — this parameter is part of the contract.

Steps: RED → implement → GREEN → full suite → commit `feat: notification prefs and pure prompt planner` → push.

---

### Task 2: App — NotificationScheduler (permission, requests, delegate, quick answers, snooze)

**Files:**
- Create: `App/Sources/Notifications/NotificationScheduler.swift`
- Modify: `App/Sources/DispatchApp.swift` (delegate wiring, foreground re-plan)
- Modify: `App/Sources/HomeView.swift` (present survey on deep-link)

**Requirements:**
- `@MainActor final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate, Observable`:
  - `requestPermissionIfNeeded()` (provisional-free, `.alert .sound .badge`).
  - `replan(context:)`: reads NotificationPrefs + AwakeStore; removes pending requests with identifier prefix `prompt-`; if asleep, stops there; else plans today (remaining) + tomorrow via PromptPlanner (seed = day's `yyyyMMdd` as UInt64 so the schedule is stable within a day but varies by day), filters past dates, creates `UNCalendarNotificationTrigger` requests with category `DISPATCH_PROMPT`, title "Time to report" / body "What are you up to right now?" (original wording of our own), identifier `prompt-<ISO date>-<index>`.
  - Category registration: quick-answer actions from the first enabled regular Yes/No question (action ids `answer-yes`, `answer-no`, titles from the question's choices or Yes/No) + `snooze` ("Snooze 15m"). Register once at startup.
  - Delegate: `didReceive` — `snooze` → schedule one `snooze-<uuid>` request +15 min (time-interval trigger, same category); `answer-yes`/`answer-no` → `ReportBuilder.save(kind: .regular, trigger: .notification, ... answers: [that one question answered])` with EMPTY outcomes (no sensor capture in the action path — documented) on the main container's context; default tap → set `pendingSurveyRequest = true` (observable) which HomeView observes to present SurveyFlowView(kind: .regular, trigger: .notification).
  - `willPresent` → `.banner` + `.sound` (show while foregrounded).
  - Next-alert readout: `nextPromptDate(completion:)` or async equivalent reading pending requests (used by settings UI).
- DispatchApp: create the scheduler as a StateObject-equivalent (@State + environment), set as UNUserNotificationCenter delegate at launch, call `requestPermissionIfNeeded()` after onboarding completes (or at startup when onboarding already done), `replan` on `scenePhase == .active`.
- HomeView: observes the scheduler (environment); presents the survey when `pendingSurveyRequest` flips; resets the flag on dismiss.

Verification: build, kit suite, UI suite (existing tests must stay green — notification permission prompts don't appear in tests because tests never trigger requestPermission before onboarding is skipped... IF the permission request fires at startup in UI tests, gate it behind the same `--mock-sensors` check to skip in tests and document). Commit `feat: notification scheduler with quick answers and snooze` → push.

---

### Task 3: App — Notification settings UI

**Files:**
- Create: `App/Sources/Settings/NotificationSettingsView.swift`
- Modify: `App/Sources/Settings/SettingsView.swift` (SCHEDULE row goes live with next-alert caption)

**Requirements (mirror the original screen):**
- NEXT NOTIFICATION section: next pending prompt time ("00:19" style, or "—" when none/asleep) + "FROM DISTRIBUTION" caption.
- FREQUENCY: "Alerts per Day" with −/count/+ stepper (1...12) → prefs.alertsPerDay + replan.
- DISTRIBUTION: three rows (Random/Semi-random/Regular) each with title + `description(alertsPerDay:)` subtitle + checkmark on selection → prefs.distribution + replan.
- SCHEDULED: list of fixed times with delete, "ADD A NOTIFICATION TIME…" → time picker sheet → prefs.scheduledTimes + replan.
- SettingsView SCHEDULE row shows "Next alert at: HH:mm" trailing caption when available.
- Themed like the rest.

Verification: build + suites. Commit `feat: notification settings screen` → push.

---

### Task 4: App Intents — StartReport, ToggleAwake, shortcuts

**Files:**
- Create: `App/Sources/Intents/DispatchIntents.swift`

**Requirements:**
- `StartReportIntent: AppIntent` (title "Start Report", `openAppWhenRun = true`): sets the same pending-survey flag the notification tap uses (shared via the scheduler/environment or a small `PendingActions` singleton — implementer's choice, documented), so the app opens into a new survey (trigger .intent).
- `ToggleAwakeIntent: AppIntent` ("Toggle Awake/Asleep", does not need to open the app): flips AwakeStore, returns a dialog stating the new state; also triggers a replan next foreground (flag).
- `DispatchShortcuts: AppShortcutsProvider` with phrases like "Start a \(.applicationName) report" and "Toggle \(.applicationName) awake".
- Note: the intent-triggered survey uses trigger `.intent` (distinguish from notification's `.notification` in the presentation path — thread a `pendingTrigger: ReportTrigger` instead of a bare bool if cleaner).

Verification: build + suites. Commit `feat: App Intents for reports and awake toggle` → push.

---

### Task 5: Wrap — planner edge tests + whole-branch review prep

**Files:**
- Test: `Tests/DispatchKitTests/PromptPlannerTests.swift` (extend)

**Requirements:**
- Add edge tests: `alertsPerDay == 1` for all three distributions (1 date, inside window); window shorter than N minutes still yields N sorted in-window dates; scheduledTimes colliding with a distribution minute dedupes (construct regular distribution landing exactly on a scheduled time).
- Run: full kit suite, app build, full UI suite. Fix anything broken.
- Commit `test: prompt planner edge coverage` → push.

## Deferred (logged for the backlog)

Visit triggers (CLMonitor), workout-end triggers, Focus Filter extension + per-Focus rules, trigger settings screen with cooldowns, sleep-derived awake window (HealthKit) — these need new targets/entitlements and are not TestFlight-blocking. The awake window for the planner is the manual AwakeStore + 08:00–24:00 default until then.
