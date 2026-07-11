# Plan-doc conventions

How plan docs under `docs/superpowers/plans/` are structured. New plans should
follow this shape so agentic workers can execute them task-by-task.

## De-facto structure (in order)

1. **Title** — `# Dispatch Plan NN: <short title>`.
2. **Agentic-worker note** — a blockquote naming the REQUIRED SUB-SKILL
   (`superpowers:subagent-driven-development` or `superpowers:executing-plans`)
   and noting that steps use checkbox (`- [ ]`) syntax.
3. **Goal** — `**Goal (issue #NN):**` — the problem and the desired end state,
   referencing the tracking issue.
4. **Architecture** — the design in prose: new types, where they live, how the
   pieces fit.
5. **Tech Stack** — the frameworks/APIs the plan leans on.
6. *(optional)* **Threat/limits model** — for security- or abuse-sensitive
   plans (see plan 42). Log the assumptions, don't hand-wave.
7. **Design decisions (decide + log)** — bulleted decisions, each stating what
   was chosen AND what was rejected and why.
8. **Observable Acceptance Criteria** — REQUIRED for UI-touching plans (see
   below).
9. **Global Constraints** — bulleted invariants that hold across every task
   (test-first rules, frozen accessibility identifiers, persistence rules,
   commit/push discipline, issue-tracking).
10. `---` divider, then **Task blocks** — `### Task N: <name>`, each with a
    **Files:** list (Create/Edit/Test), **Interfaces:** (exact names later
    tasks depend on), and checkbox (`- [ ]`) steps.
11. **Completion note(s)** — appended when the plan ships, dated, with the
    build number / PR.

## REQUIRED: Observable Acceptance Criteria

Every plan that touches UI MUST include an `## Observable Acceptance Criteria`
section. It pins **observable, screen-level** truth — what a user or an agent
can SEE on screen — so the plan can be verified without reading the diff.
Each criterion names a specific screen, the visible label / state / control,
and the frozen accessibility identifier where one exists.

Write criteria as concrete, observable statements. Examples in this app's
style:

- Home shows the awake toggle labeled **AWAKE / ASLEEP** (`awake-toggle`);
  tapping it presents the survey sheet.
- With App Lock enabled, launching the app shows the lock screen and Home
  content stays hidden until unlock succeeds.
- Sync Diagnostics is reachable from Settings and shows an **Export** button
  (`sync-diagnostics-export`) that produces a diagnostics file.

Rules:

- State what is **visible**, not how it's implemented ("the row shows
  `Weekly · Sunday · 7:00 PM`", not "the label binds to `templateSummary`").
- Reference the frozen accessibility identifier when the smoke/UI suite asserts
  on it, so the criterion and the test agree.
- Cover the primary happy path plus at least one state change or gated state
  (empty, locked, error) the change introduces.
- Non-UI (kit-only) plans may omit this section; note that they did.
