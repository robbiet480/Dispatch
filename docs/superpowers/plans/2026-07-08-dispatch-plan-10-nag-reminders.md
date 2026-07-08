# Dispatch Plan 10: Persistent (Nag) Reminders

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in escalation: if the user doesn't act on a prompt within X minutes, follow-up **time-sensitive** notifications fire repeatedly (every Y minutes, up to N times) until they take any action — quick-answer, snooze, tap-through, or filing a report in-app.

**Context (2026-07-08):** User request after build 3: "if you don't report within x minutes you start getting annoyed with time sensitive notifications repeatedly until you take an action."

## Design

**Pre-scheduled children.** iOS can't react when a prompt is ignored (the app isn't running), so nags are pre-scheduled alongside each prompt and *cancelled on action*. Each prompt `prompt-<yyyyMMdd-HHmm>` gets children `nag-<yyyyMMdd-HHmm>-<n>` (n = 1...count) at `promptDate + delay + (n-1)*interval`.

**Cancellation = taking action:**
1. `didReceive` for ANY action (yes/no/snooze/default tap) on a request whose identifier is `prompt-<stamp>` or `nag-<stamp>-<n>` → remove all pending `nag-<stamp>-*`. (Snooze counts as action; the snooze notification itself gets NO nag children.)
2. In-app report save (survey completed from any entry point) → remove pending nags whose parent stamp is in the past (they were nagging about a report that just got filed). Future prompts' nags stay.
3. Every replan removes ALL `nag-` pending requests and re-adds chains for the freshly planned prompts (same remove-before-add sequencing as prompts).

**64-pending budget.** Prompts can be up to 24 pending (2 days × 12/day). Nags per prompt are clamped: `effectiveCount = min(prefs.nagMaxCount, max(0, (60 - promptCount) / max(1, promptCount)))`. Log when clamped. With defaults (4/day → 8 prompts, 3 nags) that's 32 pending total.

**Time-sensitive.** Nag content sets `interruptionLevel = .timeSensitive` and requires the `com.apple.developer.usernotifications.time-sensitive` entitlement in `App/Dispatch.entitlements`. **Verify empirically** — after today's focus-status lesson, prove it with a real archive (`xcodebuild archive`), which is where an invalid entitlement fails. If the archive rejects it, fall back to `.active` and report back; do not ship a guess. Original prompts stay `.active`-default — only nags break through.

**Copy.** Nag title: "Still waiting on your report" (escalation is the interruption level + repetition, not shouty text). Body: same question-stating body as prompts (`makeContent`); same `DISPATCH_PROMPT` category so quick answers work directly from a nag.

## Global Constraints

- No delegation by implementers; suites green (117 kit + 6 UI) before every commit; commit + push per task; `git pull --rebase` before starting and before pushing.
- All scheduling test-gated as today (`--mock-sensors`/`--ui-testing` → no-ops).
- Feature is OFF by default (`nagEnabled = false`) — build 4 testers opt in.

---

### Task 1: Kit — prefs + pure nag planner

**Files:** Modify `Sources/DispatchKit/Prompting/NotificationPrefs.swift`; create `Sources/DispatchKit/Prompting/NagPlanner.swift` + `Tests/DispatchKitTests/NagPlannerTests.swift`.

**Contract:**
- `NotificationPrefs` gains (UserDefaults-backed, same style as existing): `nagEnabled: Bool` (default false), `nagDelayMinutes: Int` (default 10, clamp 1...120), `nagIntervalMinutes: Int` (default 5, clamp 1...60), `nagMaxCount: Int` (default 3, clamp 1...10).
- `NagPlanner.plan(promptDates: [Date], delayMinutes: Int, intervalMinutes: Int, maxCount: Int, budget: Int) -> [(parent: Date, fires: [Date])]` — pure, deterministic. Applies the budget clamp (`min(maxCount, (budget - promptDates.count) / max(1, promptDates.count))`, floor 0). Returns empty fires arrays when clamped to 0 or maxCount 0.
- Tests: chain math (delay + interval spacing), budget clamping at 12/day×2, zero-prompt input, defaults round-trip on prefs, clamping bounds.

Verify: `swift test` (117 + new green). Commit `feat(kit): nag reminder prefs + planner` → push.

### Task 2: App — scheduler wiring, cancellation, entitlement, settings UI

**Files:** Modify `App/Sources/Notifications/NotificationScheduler.swift`, `App/Sources/Settings/NotificationSettingsView.swift`, `App/Dispatch.entitlements`; the in-app-save cancellation hook goes wherever survey save completes (grep for the `ReportBuilder.save` call sites in the survey flow / SurveyPresenter path).

**Contract:**
- `NotificationIdentifiers.nagPrefix = "nag-"`. Nag identifier format: `nag-<yyyyMMdd-HHmm>-<n>` (reuse `isoMinuteFormatter` stamp of the parent).
- `replanNow`: also remove all `nag-` pending (both awake and asleep paths); when awake and `prefs.nagEnabled`, after adding prompts, add nag chains from `NagPlanner.plan(budget: 60)`, skipping fires ≤ now. Nag content = `makeContent` + title "Still waiting on your report" + `.timeSensitive` interruption + same category.
- `didReceive`: extract the parent stamp from the responding request's identifier (`prompt-` or `nag-` prefixed); on every action branch, remove pending `nag-<stamp>-*` before/alongside existing handling. Snooze notifications (uuid identifiers) have no stamp — no-op.
- New `func reportFiled(now: Date = Date())` on the scheduler: removes pending nags whose parent stamp parses to a date ≤ now. Call it after successful in-app survey save (find the completion path; ContentView/HomeView already hold the scheduler in the environment).
- Entitlement: add `com.apple.developer.usernotifications.time-sensitive` = true to `App/Dispatch.entitlements`. Prove with `xcodegen generate` then a real archive (`xcodebuild archive -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS' -archivePath /tmp/nag-check.xcarchive CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=UTQFCBPQRF 2>&1 | tail -5`) → ARCHIVE SUCCEEDED. If signing rejects the entitlement, remove it, use `.active`, and flag in the report.
- Settings UI: new "Persistent Reminders" section in NotificationSettingsView — Toggle (identifier `nag-enabled`), and when on: "Remind after" (minutes picker/stepper), "Repeat every", "Max reminders". Footer: "Follow-up reminders are Time Sensitive and can break through Focus modes. They stop as soon as you act on a prompt or file a report." Changing any value triggers a replan (same pattern as existing controls).
- Nothing else changes: prompt identifiers, snooze behavior, quick-answer filing untouched.

Verify: build, `swift test`, UI suite (6/6), archive check above. Commit `feat: time-sensitive nag reminders until action taken` → push.
