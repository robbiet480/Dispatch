# Dispatch Plan 18: Insights — correlations across your reports

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** surface honest, on-device correlations across report data — "Days you report a workout average 2,400 more steps", "You answer 'Yes' to working on 84% of reports at Office", "Your mood valence runs higher on days you see Angela" — in a dedicated Insights screen and woven into the weekly digest.

## Design decisions (decide + log)

- **Pure kit statistics, deliberately modest.** `InsightsEngine.compute(reports:questions:) -> [Insight]` in DispatchKit: pairwise associations between (a) categorical signals — yes/no answers, multi-choice options, tokens/people/places presence, weather condition, Focus name — and (b) numeric signals — number answers, steps, dB, State-of-Mind valence, workout minutes, flights. Methods: difference of means for categorical×numeric (report the delta, not a test statistic), co-occurrence rates for categorical×categorical. **Honesty guards:** minimum sample sizes (≥10 reports on each side of a split), minimum effect thresholds (skip trivial deltas), capped output (top 8 by normalized effect), plain "tends to"/"average" language — never causal claims. Deterministic ordering. Fully unit-tested with synthetic fixtures (known correlation in → surfaced; noise in → silence; below-threshold → silence).
- **Insight model:** value type (title sentence, detail sentence, kind, strength 0-1, sample count) — presentation-ready from kit, no schema/model changes anywhere.
- **Insights screen:** Home overflow/Settings entry alongside Weekly Digest; cards list with sample-count captions ("based on 34 reports"); empty state explains it needs ~2 weeks of reports; computed off-main with the memoized-viz pattern; respects the visualization content filters? NO — insights always run over all reports (decide + log: filtered insights invite spurious conclusions from tiny subsets).
- **Digest integration:** `DigestStats` gains the week's top 2 insights (computed over all-time data but only shown when stable); template + LLM prompts updated (LLM still stats-only — insights arrive as precomputed sentences it may weave in, not derive).

## Global Constraints

- No delegation; suites green before every commit (counts from Plan 17's final report); commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is standing instruction). No new entitlements. No schema changes. Do NOT bump the build number.

---

### Task 1: Kit — InsightsEngine

**Files:** new `Sources/DispatchKit/Insights/InsightsEngine.swift`, `Insight.swift` + tests.
**Contract:** per design above; fixtures prove surfacing, silence-on-noise, thresholds, determinism, language templates.
Verify: `swift test`. Commit `feat(kit): insights engine` → push.

### Task 2: App — Insights screen + digest weave

**Files:** new `App/Sources/Insights/InsightsView.swift`; entry point; `Sources/DispatchKit/Digest/DigestStats.swift` + digest views/prompt.
**Contract:** per design above; +1 UI test (screen opens, renders empty state under --mock-sensors). Wrap: full suites; completion note.
Verify: build, kit suite, UI suite. Commit `feat: insights screen + digest integration` → push. Whole-branch review follows (controller-driven).
