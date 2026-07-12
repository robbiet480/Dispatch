Build 30 (version 1.0) — supersedes 29; use this one.

NEW
- Place & beacon triggers (plan 45): two new prompt-group schedules — "When I arrive at / leave a place" and "When I'm near a beacon" — each with an optional delay. Built on CLMonitor; both need "Always" location, requested in the group editor only when you pick one of these schedules.
- Correlation insights (plan 34): the Insights screen now surfaces correlations between your questions, with per-question drill-in. Uses honest confidence intervals with eligibility gating and a plain-language "correlation isn't causation" disclaimer — no overclaiming.
- Siri Shortcuts / App Intents (plan 49): report-centric shortcuts so you can file or open a report from Siri, the Shortcuts app, and the share sheet across iPhone, watch, and Mac.
- Automatic awake/asleep (plan 39): an opt-in setting derives your awake/asleep state from a Sleep Focus and HealthKit sleep analysis, and corrects itself when sleep data arrives after you wake.

ALSO
- Change-since-last-report heart-rate window (plan 43): a captured "heart rate range" over the window since your last report, with a settings row to enable it.
- macOS companion (plan 47): manage questions and prompt groups on the Mac, and browse / add / submit catalog questions. Place/beacon groups created on iPhone show read-only on the Mac (the trigger stays as set on iOS).
- Catalog hardening: duplicate-submission prevention (plan 42 — add-instead when a question already exists) and per-device submission rate limiting (plan 38).
- Fixes: Mac dashboard charts honor the sidebar search; workouts that end while you're asleep are no longer dropped; digest one-sentence-per-question dedupe; block-chart contrast.

WHAT TO TEST
1. Place trigger: create a prompt group "When I arrive at / leave a place", pick a place and a delay, grant "Always" location, then arrive at / leave that place — confirm the prompt arrives after the delay and the report shows the place trigger. Toggling to "leave" should fire on departure.
2. Beacon trigger: create a beacon group (UUID, optionally major/minor), get near / leave the beacon — confirm the prompt fires and the report carries the beacon metadata. (A minor without a major is rejected — set major first.)
3. Correlations: open Insights → correlations, drill into a question — confirm intervals render, the causation disclaimer shows, and low-data questions are gated out rather than shown as strong correlations.
4. Siri Shortcuts: add the "file a report" shortcut, run it from Siri and from the Shortcuts app — confirm it opens/files a report on iPhone and watch.
5. Auto awake/asleep: enable the automatic sleep-state setting, use a Sleep Focus overnight — confirm the app shows asleep during the Focus and corrects to the right state after HealthKit sleep data lands.
