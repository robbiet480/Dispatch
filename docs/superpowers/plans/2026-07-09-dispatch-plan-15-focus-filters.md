# Dispatch Plan 15: Focus Filters — named Focus capture + per-Focus prompt groups

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (user request, 2026-07-09):** implement a Focus Filter (`SetFocusFilterIntent`) so (a) reports capture the *name* of the active Focus (today: boolean only via INFocusStatusCenter), and (b) each Focus mode can limit which Prompt Groups fire while it's active — "in Work Focus, only ask the Work group's questions."

## Design decisions (decide + log)

- **The filter's parameters:** a `displayName` string (the label captured into reports, e.g. "Work") + a multi-select of Prompt Groups (dynamic `AppEntity` options queried from the shared store — the App Group store move makes this possible from any process) + a `pauseGlobalPrompts` Bool (default false) controlling whether the ungrouped/global schedule keeps firing during this Focus.
- **Semantics:** while a Dispatch filter is active → replan schedules ONLY the selected groups (+ global unless paused); everything else is removed from pending (the existing remove-before-add replan batch does this for free). Filter deactivates (Focus off or switched) → full schedule resumes on the deactivation callback's replan. A Focus with NO Dispatch filter configured changes nothing. Nag chains follow their parents automatically (removed with them, budget recomputed).
- **State plumbing:** `FocusFilterState` (Codable: label, allowedGroupIDs, pauseGlobal, activatedAt) persisted in the App Group defaults. The intent's `perform()` writes it (and clears it on deactivation — check the SetFocusFilterIntent lifecycle: the system invokes the filter on activation and there's a reset/deactivation path — verify against the AppIntents docs/headers, don't recall it) and triggers a replan. VERIFY EMPIRICALLY which process runs `perform()` (docs say the system can launch the app in the background for filter intents) — if it's not the main app process, the replan must be triggerable from the state alone at next launch/foreground + a Darwin/defaults observation; document what's actually observed on the simulator.
- **Focus name capture:** `FocusProvider` reading becomes "Work" (the state's label) when a filter is active, falls back to today's boolean text otherwise. Detail view renders the name. Stored reading format stays a string — additive, no schema change.
- **Discoverability:** Settings → Notifications gains a passive status row when a filter is active ("Focus filter: Work — 2 groups"), plus a one-time hint row in the Focus sensor's settings pointing at Settings → Focus → [mode] → Focus Filters (Apple provides no in-app enrollment; say so in the footer).
- **No new entitlements expected** — SetFocusFilterIntent is plain AppIntents. If implementation discovers otherwise, archive-prove per session rule before relying on it.

## Global Constraints

- No delegation; suites green before every commit (253 kit + 9 UI at start); commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is the repo owner's standing instruction).
- Test-gated: filter state ignored under `--ui-testing`/`--mock-sensors` unless a test injects it; no schema changes; replan sequencing discipline (single removal batch) untouched.

---

### Task 1: Kit — FocusFilterState + plan filtering

**Files:** new `Sources/DispatchKit/Prompting/FocusFilterState.swift` + tests; touch `GroupPlanner`/scheduler-input shaping only if the filtering can't stay a pure pre-filter.

**Contract:**
- `FocusFilterState`: Codable + defaults-suite read/write helpers (same style as NotificationPrefs); `isActive`, `allows(groupID:) -> Bool`, `allowsGlobal: Bool`.
- Pure filtering helper the scheduler will call: given enabled groups + optional state → the groups to plan + whether to plan global. Tests: nil state (everything), active state (subset), pauseGlobal, empty allowed set (groups all muted, global per flag), round-trip persistence.

Verify: `swift test`. Commit `feat(kit): focus filter state + plan filtering` → push.

### Task 2: App — SetFocusFilterIntent + scheduler/provider/UI wiring

**Files:** new `App/Sources/Intents/DispatchFocusFilter.swift` (intent + PromptGroup AppEntity/options provider reading the shared store read-only), `App/Sources/Notifications/NotificationScheduler.swift` (consult the state in replanNow), `App/Sources/Providers/FocusProvider.swift` (label), `App/Sources/Settings/` (status row + hint), `App/Sources/DispatchApp.swift` (wiring if the intent needs the replan hook — same pattern as StartReportControlIntent's hook).

**Contract:**
- `DispatchFocusFilter: SetFocusFilterIntent` with the three parameters; `perform()` writes/clears FocusFilterState and triggers replan through the registered hook when running in-app (empirically verify the process + deactivation lifecycle; document in code comments what the simulator showed — set a Focus in the sim Settings and observe). Dynamic group options titled by group name.
- replanNow: apply the kit filtering helper before planning (global + groups); nag/budget math unchanged downstream.
- FocusProvider: label from active state; boolean fallback.
- Settings rows as designed. UI test: with an injected FocusFilterState (launch-arg/test hook writing the defaults), the notification settings row shows the label — keep it deterministic, no real Focus needed.
- README: short Focus Filters section (what it does, the per-mode setup steps, the pause-global toggle).

Verify: build, kit suite, UI suite (9+1), archive (entitlements unchanged — confirm no new requirement surfaced). Commit `feat: focus filters — named focus capture + per-focus prompt groups` → push. Whole-branch review follows (controller-driven).
