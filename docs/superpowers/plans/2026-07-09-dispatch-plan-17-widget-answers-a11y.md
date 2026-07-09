# Dispatch Plan 17: Interactive widget quick-answers + accessibility & hygiene

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) answer the quick-answer Yes/No question directly from the home-screen widget — tap, report filed, no app launch; (2) a VoiceOver/Dynamic Type accessibility pass over the custom UI; (3) the reviewer-minor hygiene backlog.

## Hard constraint

**NO new entitlements** (profiles pinned — same rule as Plan 16).

## Design decisions (decide + log)

- **Widget quick-answer = interactive `Button(intent:)`** on the medium widget (small stays tap-to-open): when an enabled regular Yes/No question exists, the medium family shows its prompt + two buttons. The intent (`QuickAnswerIntent`, parameters: question ID + choice index) files the same minimal report as the notification quick-answer path (trigger `.notification`-analog — add `.widget` as a new additive ReportTrigger raw value for honest attribution).
- **EMPIRICALLY verify which process runs a widget button's perform()** (session rule): Apple documents widget App Intents as running in the app's process in the background — prove it with a probe (log the process name from perform()). Filing must work from whatever process it actually is: report save via the shared App Group store, `lastActedAt` update, pending-nag cancellation, and a `WidgetCenter` reload. If any side effect (e.g. `UNUserNotificationCenter` removal) proves unavailable in the executing process, persist a pending-action marker the app drains at next launch/foreground and document — never silently skip the side effect.
- **The widget's question content** comes from the same shared-store read-only fetch the timeline already does; after filing, the button state flips to a transient "Filed ✓" (timeline reload shows the updated counts).
- **Accessibility scope:** proportion bands (per-band label: "No, 69 percent"), tokens frequency page, numeric graph (audio graph/summary), capture checklist rows (state + hint), FlowingChips (token add/remove actions), schedule chips, filter chips, widget views (accessory families especially), AppLockView. Dynamic Type: survey question text, detail rows, settings — no clipped/truncated text at XXL; test at `.accessibility3` in one UI test via launch environment if feasible, otherwise structural + documented.
- **Hygiene items (from build-13 review):** (a) pin `en_US_POSIX` on the scheduler stamp formatter + one-time versioned full replan so re-stamped identifiers can't orphan pending prompts (comment the tradeoff); (b) `BackupManager.refreshCount` off the launch critical path (async) + URL-based directory listing; (c) comment the batched-visit drop bias in VisitObserver; (d) digest reverse-order handoff comment/guard per review note 2.

## Global Constraints

- No delegation; suites green before every commit (273 kit + 12 UI at start); commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is the repo owner's standing instruction). Test-gate everything as usual. Do NOT bump the build number.

---

### Task 1: Widget quick-answers

**Files:** new `App/Sources/Intents/QuickAnswerIntent.swift` (dual target membership via project.yml, same pattern as StartReportControlIntent); `Widgets/Sources/` (medium-family layout + buttons); `Sources/DispatchKit/Models/Values.swift` (ReportTrigger.widget, additive + v2 tolerance test); the quick-answer filing path refactored so notification and widget share one kit-side function if they don't already.

**Contract:** per the design decisions above — probe-verified execution process documented in a code comment; filing side effects complete (or marker-drained); UI test not feasible for widget interaction — kit test the shared filing function (report shape, trigger, lastActedAt) instead; build + suites green.

Verify: build, kit suite, UI suite, archive (entitlements unchanged). Commit `feat: answer quick questions from the widget` → push.

### Task 2: Accessibility pass

**Files:** as audited — visualization views, survey views, settings chips/rows, widget views, AppLockView.

**Contract:** every custom interactive element has an accessibilityLabel/value/hint where the default is wrong or empty; decorative elements hidden; proportion bands and frequency lists read meaningfully; Dynamic Type survives XXL without clipped controls (fixes where it doesn't). Deliver an audit table in the report (element → before → after). No behavior changes.

Verify: build, kit suite, UI suite. Commit `feat: VoiceOver and Dynamic Type pass` → push.

### Task 3: Hygiene + wrap

**Files:** `App/Sources/Notifications/NotificationScheduler.swift` (POSIX pin + versioned replan marker), `App/Sources/Backup/BackupManager.swift`, `App/Sources/Providers/VisitObserver.swift`, `App/Sources/ContentView.swift`/digest handoff.

**Contract:** per hygiene list above; the POSIX one-time replan is guarded by a defaults version marker (fires exactly once per install, logged). Wrap: full suites; completion note here.

Verify: build (warning-free), kit suite, UI suite. Commit `chore: stamp locale pin, launch I/O, review minors` → push. Whole-branch review follows (controller-driven).
