# Dispatch Plan 35: Live Activity — streak at risk + pending prompt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A lock-screen / Dynamic Island Live Activity that keeps the day's Dispatch state glanceable outside the app: the current streak, whether today is filed, a countdown to midnight when the streak is at risk, and — when honestly knowable — an unanswered prompt waiting. Started only from the app's foreground hooks (an ActivityKit hard constraint, see design decisions), updated on file/replan, ended on file or at midnight. Tracks GitHub issue #20 — reference it in commits/PRs.

**Scope discipline (hard constraints):** ONE activity type, app-started only. No push-to-start, no APNs, no `com.apple.developer.liveactivity` push-update entitlement, no server — Dispatch is local-only and stays that way. No watch/iPad work. No new kit schema. Existing widgets (`DispatchStatusWidget`, `DispatchControlWidget`) untouched except the bundle registration. Config change is a single `INFOPLIST_KEY_NSSupportsLiveActivities` on the app target — no provisioning-profile churn.

## Design decisions (decide + log)

- **The headline use from issue #20 ("prompt fired → Live Activity") is impossible as stated, and this plan says so rather than pretending.** Verified against Apple's ActivityKit documentation (developer.apple.com/documentation/activitykit, checked 2026-07-10): a Live Activity can be started only (a) by the app **while it is in the foreground** (`Activity.request`), or (b) by an **APNs push-to-start** remote notification (iOS 17.2+), which requires a server holding push-to-start tokens. A **local** notification firing while the app is closed cannot start an activity, and neither can a background task or background app refresh. Dispatch's prompts are all local notifications from `NotificationScheduler`, and Dispatch has no server — so "activity appears when the prompt fires in your pocket" is off the table. **v1 pivots to the strongest honest use: a foreground-started "day state" activity** whose primary story is *streak at risk* (today unfiled, streak alive, midnight approaching — exactly the moment `ReportStreak` treats as "not broken yet"), with *pending prompt* folded in as content state whenever the app is foreground at a moment it can know about one. This is logged here as the plan's central design decision per the issue triage.
- **One activity type, `DispatchDayActivityAttributes`, with all variability in `ContentState`.** Static attributes: the local calendar day the activity describes (`dayStart: Date`). ContentState: `streakDays: Int`, `filedTodayCount: Int`, `pendingPromptGroupName: String?`, `pendingPromptFiredAt: Date?`, plus a derived `atRisk` rendering (unfiled + streak > 0). One activity means one lifecycle to reason about and no duplicate-island juggling; "prompt pending" and "streak at risk" are the same glanceable surface in different states, not two activities.
- **Start triggers (all provably foreground):** (1) scenePhase `.background` transition — the moment the user *leaves* the app is when a lock-screen surface starts paying rent; start if today is unfiled, `streakDays > 0`, and local time ≥ the at-risk threshold (17:00). (2) scenePhase `.active` (foreground replan hook already in `DispatchApp`) under the same conditions — covers "opened the app in the evening, got distracted, locked the phone". (3) `NotificationScheduler.userNotificationCenter(_:willPresent:)` — a prompt arriving **while the app is foreground** starts/updates the activity with the pending-prompt state (this is the only honest slice of the original pending-prompt ask, and it's kept). At foreground, `deliveredNotifications()` is additionally consulted so an already-delivered unanswered `DISPATCH_PROMPT` populates `pendingPromptGroupName` on start/update.
- **At-risk threshold = 17:00 local, constant in kit code, not a setting (v1).** Starting the activity on every morning foreground would be noise; the streak isn't "at risk" until the day is running out. 17:00 → midnight is a ≤ 7-hour window, comfortably inside ActivityKit's 8-hour active budget, so the budget never truncates us. The threshold lives in the kit decision function where it is unit-tested and trivially promotable to a preference later.
- **End triggers:** `reportFiled` (already centralized in `NotificationScheduler.reportFiled`, called from `SurveyFlowView` and the synced/quick-answer paths) updates the activity to a "filed — streak N" celebratory final state and ends it with `.after(now + 30 min)` dismissal so the win lingers briefly on the lock screen. Midnight: `staleDate` = next local midnight on every request/update, so iOS greys the activity the instant the day rolls over even though no code runs; the next app foreground ends any stale activity for a previous `dayStart` immediately (and may start a fresh one for the new day). Belt-and-braces: `Activity.request` is never issued for a `dayStart` that already has a live activity — update instead (idempotent lifecycle, mirrors the replan's remove-before-add discipline).
- **Decision logic is pure kit code; ActivityKit calls are a thin app-side shell.** `ActivityKit` is iOS-only and `swift test` runs the kit on macOS, so DispatchKit gets a Foundation-only `LiveActivityPlanner` (input: `WidgetSnapshot`-shaped data + now/calendar + current-activity state; output: `.start(content)/.update(content)/.end(content)/.none`) with full unit tests, exactly the `WidgetSnapshot`/`ReportStreak` precedent from plan 14. The `ActivityAttributes` conformance cannot live in the kit for the same reason — it goes in a dual-target-membership file `Shared/LiveActivity/DispatchDayActivityAttributes.swift` compiled into BOTH DispatchApp and DispatchWidgets, the established plan-19 pattern (`Shared/Providers` in `project.yml`).
- **Presentations:** lock screen banner = streak flame + count, "today unfiled" line with `Text(timerInterval:)` counting down to midnight when at risk, or "⏳ <group> prompt waiting" when pending. Dynamic Island: compact leading = flame + streak count; compact trailing = countdown (at risk) or bell (pending); minimal = flame; expanded = full state + a "File report" `Link` to `dispatch://report?trigger=live-activity` — the existing widget deep-link route in `DispatchApp` (plan 17), extended to accept the new trigger value for provenance stamping.
- **Config: `INFOPLIST_KEY_NSSupportsLiveActivities: YES` on the DispatchApp target in `project.yml`. That is the complete requirement for locally-started, locally-updated activities.** No entitlement is needed (the Live Activity push entitlements matter only for APNs-updated activities — out of scope), and `NSSupportsLiveActivitiesFrequentUpdates` is NOT set (a handful of updates per day is nowhere near the frequent-updates tier and the key invites App Review questions). Verify in the built product's Info.plist, plan-16/27 style — INFOPLIST_KEY variants have burned us before.
- **Respect the system switch:** gate every `request` on `ActivityAuthorizationInfo().areActivitiesEnabled` and observe `activityEnablementUpdates` to end cleanly if the user flips Live Activities off in Settings. No in-app toggle in v1 — the OS-level per-app switch is the control surface; an app preference would be a second switch that can silently disagree with it.
- **Testing posture:** kit planner logic is exhaustively unit-tested (threshold edges, midnight rollover, filed-today, pending-prompt precedence, idempotent start). ActivityKit itself is not UI-testable (activities render out-of-process on the lock screen/island); the wrap task carries a manual on-device verification checklist instead of pretending a simulator assertion covers it. UI suite must simply stay green — the feature adds no in-app UI beyond the deep-link trigger value.

## Global Constraints

- Suites green before every commit: `swift test` + `xcodebuild build-for-testing` (iPhone simulator destination). Kit changes land TDD-first. No build-number bump. Every claimed ActivityKit behavior in comments cites the docs page (four-strikes rule) — especially the foreground-start constraint, which future readers will be tempted to "fix".
- Branch workflow: worktree branch `plan-35-live-activity`, scoped commit per task, rebase on main before the PR. PR at the end titled `feat: Live Activity — streak + pending prompt (plan 35)`, referencing #20.

---

### Task 1: project.yml — NSSupportsLiveActivities

- [ ] **Files:** `project.yml` (DispatchApp target: `INFOPLIST_KEY_NSSupportsLiveActivities: YES`).

**Contract:** `xcodegen generate` succeeds; built app Info.plist contains `NSSupportsLiveActivities = true` (verify in the built product). Widgets target needs nothing — activity UI ships in the existing widget extension, which requires no extra plist key.

Verify: kit suite + build-for-testing. Commit `feat: declare Live Activity support (plan 35)`.

### Task 2: kit — LiveActivityPlanner (TDD)

- [ ] **Files:** Create `Sources/DispatchKit/Widgets/LiveActivityPlanner.swift` (pure Foundation: content struct `LiveActivityContent` — streakDays, filedTodayCount, pendingPromptGroupName/firedAt, dayStart, staleDate(next local midnight); decision function taking snapshot data + optional current-activity `dayStart`/content + now/calendar, returning start/update/end/none; 17:00 at-risk threshold constant). Create `Tests/DispatchKitTests/LiveActivityPlannerTests.swift`.

**Contract:** covered cases at minimum — before/after threshold; unfiled+streak>0 → start; filed today → end-with-celebration (from live) / none (from idle); streak 0 → pending-prompt-only starts (a prompt waiting justifies the surface even with no streak); existing activity same day → update not start; activity from a previous `dayStart` → end; midnight staleDate math across DST. Reuses `WidgetSnapshot`/`ReportStreak` — no duplicated streak math.

Verify: `swift test`. Commit `feat(kit): Live Activity planner + tests (plan 35)`.

### Task 3: shared attributes + widget-extension activity UI

- [ ] **Files:** Create `Shared/LiveActivity/DispatchDayActivityAttributes.swift` (`ActivityAttributes` wrapping the kit `LiveActivityContent` as ContentState; dual membership DispatchApp + DispatchWidgets via `project.yml` sources, plan-19 `Shared/Providers` pattern). Create `Widgets/Sources/DispatchDayLiveActivity.swift` (`ActivityConfiguration`: lock-screen banner + Dynamic Island compact/expanded/minimal per the design decision; `Link` to `dispatch://report?trigger=live-activity`). Modify `Widgets/Sources/DispatchWidgetsBundle.swift` (register the activity), `project.yml` (Shared/LiveActivity path on both targets).

**Contract:** extension builds; presentations render in previews for at-risk, pending-prompt, and filed states; no store access from activity views (ContentState carries everything — activities re-render from state, never fetch).

Verify: kit suite + build-for-testing. Commit `feat: Live Activity presentations (plan 35)`.

### Task 4: app — LiveActivityManager + lifecycle hooks

- [ ] **Files:** Create `App/Sources/Notifications/LiveActivityManager.swift` (owns `Activity<DispatchDayActivityAttributes>` handles; executes planner verdicts; gates on `areActivitiesEnabled`; observes `activityEnablementUpdates`; ends stale prior-day activities at foreground). Modify `App/Sources/DispatchApp.swift` (invoke from the existing scenePhase `.active` replan hook and `.background` transition), `App/Sources/Notifications/NotificationScheduler.swift` (`willPresent` → pending-prompt start/update; `reportFiled` → celebratory end; foreground path consults `deliveredNotifications()` for unanswered prompts), deep-link trigger allowlist for `live-activity` (plan-17 provenance route in `DispatchApp`).

**Contract:** no `Activity.request` ever issued from a non-foreground context (comment cites the ActivityKit doc); duplicate-start impossible (same-day live activity → update); filing a report from ANY path (survey, quick answer, synced) ends the activity via the centralized `reportFiled`; disabling Live Activities in Settings ends live activities on the next enablement update.

Verify: kit suite + build-for-testing; UI suite spot-run of survey filing stays green. Commit `feat: Live Activity lifecycle manager (plan 35)`.

### Task 5: wrap — manual verification + PR

- [ ] **Files:** this doc (completion notes + manual checklist results).

**Contract:** manual on-device checklist executed and recorded: (1) evening unfiled + streak → background the app → activity appears with countdown; (2) file the report → celebratory state, dismisses within ~30 min; (3) prompt fires while app foreground → pending state appears; (4) cross midnight → activity greys (stale) and is ended at next open; (5) Settings → Dispatch → Live Activities OFF → activity ends. Full UI suite green. Rebase on main, PR `feat: Live Activity — streak + pending prompt (plan 35)` referencing #20.

Verify: `swift test` + full UI suite. Commit `docs: plan 35 completion notes`.
