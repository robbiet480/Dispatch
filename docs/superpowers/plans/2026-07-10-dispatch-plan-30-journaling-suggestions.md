# Dispatch Plan 30: Journaling Suggestions

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** adopt the JournalingSuggestions framework as a new ad-hoc report entry point — a "From a moment…" button presents Apple's system suggestions picker (workouts, photos, visits, contacts, songs, state of mind…); choosing a moment opens the normal survey pre-filled with that moment's context (title + date), and the saved report records which suggestion prompted it. Tracks GitHub issue #15 — reference it in commits/PRs.

**Scope discipline (v1 hard constraints):** picker-initiated ad-hoc reports ONLY. No background suggestion notifications (`JournalingSuggestionsConfiguration` is deferred scope), no per-item content extraction beyond title/date (no photo/workout asset ingestion — the report's own sensor capture already covers health/location), no watch work (framework is iOS-only). The entitlement request is external and non-blocking; every code task ships without waiting on it.

## Framework facts (doc-verified 2026-07-10, developer.apple.com/documentation/journalingsuggestions)

- **UX model is a system picker, NOT polling.** The app renders a `JournalingSuggestionsPicker` button; tapping it presents a system sheet of recent moments (first presentation shows a system intro sheet). Only when the person picks a suggestion does the app receive data — and only that suggestion's data. There is no API to enumerate suggestions in the background.
- **API surface used in v1:** `JournalingSuggestionsPicker(_:onCompletion:)` (`onCompletion: (JournalingSuggestion) async -> Void`); `JournalingSuggestion` exposes `title: String`, `date: DateInterval?`, `items: [JournalingSuggestion.ItemContent]`, and `content(forType:) async -> [Content]` with nested content types (`Workout`, `Contact`, `Photo`, `Location`, `StateOfMind`, `Song`, …). v1 reads only `title` + `date`.
- **Entitlement:** `com.apple.developer.journal.allow` ("An entitlement that enables an app to present the journaling suggestions picker") — a REQUEST-BASED managed capability; Apple approval required before the picker functions, in dev builds too.
- **Availability:** iOS 17.2+ / iPadOS 26.0+ — both below our 26.0 deployment target, so no `#available` gating; framework import is app-target-only (DispatchKit stays Foundation/SwiftData-only).

## Design decisions (decide + log)

- **A suggestion becomes a `SurveyRequest`, not a new filing path.** The picker's `onCompletion` builds a `SurveyRequest` (`App/Sources/SurveyPresenter.swift`) and hands it to the existing `SurveyPresenter` — the same landing pad every other trigger uses (manual, control, widget, intent, notification). Full survey, full sensor capture, same save path through `SurveyController.save(in:)` → `ReportBuilder.save`. No shortcut filing.
- **Trigger attribution = additive `ReportTrigger.journalingSuggestion` raw value** in `Sources/DispatchKit/Models/Values.swift` — the exact `.watch` pattern (older builds decode it via the `.manual` fallback; v2 export tolerance test, same as `.widget`/`.watch` were).
- **Pre-filled context = two additive optional fields on `Report`:** `journalingSuggestionTitle: String?` (the suggestion's title, e.g. "Morning Run") and the existing date machinery. Date rule (kit-pure, tested): a moment whose `DateInterval` **ended before "recently"** (> 30 minutes ago) files as a **backdated** report at the interval's END date (`SurveyRequest.overrideDate` → `isBackdated`, sensor capture skipped — capturing now-sensors for yesterday's hike would be wrong data); a current/ongoing moment files live (overrideDate nil, full capture). A nil `date` files live. This mapping lives in kit as `JournalingMomentMapper` so it's testable without the framework.
- **No `JournalingSuggestion` type crosses into kit.** The app-side entry button destructures the suggestion into `(title: String, date: DateInterval?)` before calling the kit mapper — kit stays framework-free and the mapper is unit-testable with plain values.
- **Entry point placement: Home REPORT area, not a Menu item.** `JournalingSuggestionsPicker` is itself a SwiftUI button view (it cannot be a `Menu` row), so it renders as its own labeled control beneath/beside the REPORT button in `App/Sources/HomeView.swift` (near the existing `SurveyRequest(kind: .regular, trigger: .manual)` sites, lines ~313–329), styled to match and carrying accessibility identifier `journaling-suggestions-button`. Hidden entirely when the settings toggle is off.
- **Settings toggle, default OFF until the entitlement grant.** `AppDefaults`-backed `journalingSuggestionsEnabled` toggle in `App/Sources/Settings/SettingsView.swift` (the established `Toggle(isOn: Binding(...))` + `@Environment(\.appDefaults)` pattern), footer text explaining the system picker + privacy story ("Apple shares only the moment you pick"). **No fragile runtime entitlement sniffing** (there is no public iOS API for it): the toggle defaults OFF; flipping the default to ON ships with the entitlement-grant checklist item, the plan-19 device-name playbook. Until then a curious tester who enables it gets a button whose system sheet the OS declines to fill — acceptable for a default-off toggle, and the footer says "requires Apple approval; may be empty until then".
- **Entitlement request is EXTERNAL and NON-BLOCKING** — mirrors `com.apple.developer.device-information.user-assigned-device-name` exactly (plan 19, checklist item + plan-25 profile-regen drill): Robbie submits the request; no task waits on it; on grant, `com.apple.developer.journal.allow` lands in `App/Dispatch.entitlements` (app target ONLY — not widgets, not watch), capability enabled on the bundle-ID resource, pinned App Store profiles regenerated via the ASC API recipe (session ledger 2026-07-08; bundle IDs 2532PZDYH6/VYY3Q8UZPQ), archive + `codesign -d --entitlements` proof, toggle default flipped ON.
- **Report detail + export:** `ReportDetailView` shows the suggestion title as a context row (alongside the existing backdated badge, line ~221); v2 export carries `journalingSuggestionTitle` additive-optional with encode-when-present/decode-leniently + round-trip AND absence-tolerance tests — the `sourceDeviceName` drill (`Sources/DispatchKit/V2/V2Models.swift` ~line 137, `V2Exporter.swift` ~line 81).
- **Test gating:** the picker is a system sheet and CANNOT be exercised by the UI suite (and won't function pre-entitlement anyway). UI tests assert entry-button presence/absence against the toggle only; the mapper + schema + plumbing are kit-tested. Nothing about the feature touches sensors/CloudKit under test args — unchanged guarantees.

## Global Constraints

- Suites green before every commit (`swift test` + UI suite where app UI changes); scoped commits + push; `git pull --rebase` before starting/pushing. Do NOT bump the build number. Additive schema only — this plan's entire schema delta: optional `journalingSuggestionTitle` on `Report` + the `ReportTrigger.journalingSuggestion` raw value. NO entitlement/profile changes in any code task (the grant checklist item is the only place they happen, and it is archive-proven before its commit — plan-25 drill). Accessibility on new UI per the plan-17 bar. Every platform-behavior claim in comments cites a doc URL (four-strikes rule).

---

### Task 1: Kit — trigger case, report field, export (TDD)

- [ ] **Files:** Modify `Sources/DispatchKit/Models/Values.swift` (`ReportTrigger.journalingSuggestion`, additive, doc comment mirroring `.watch`), `Sources/DispatchKit/Models/Report.swift` (`journalingSuggestionTitle: String?`, additive optional, no migration), `Sources/DispatchKit/Capture/ReportBuilder.swift` (`save(...)` gains `journalingSuggestionTitle: String? = nil`, stamped onto the report), `Sources/DispatchKit/V2/V2Models.swift` + `V2Exporter.swift` (additive-optional field, encode-when-present). Tests first in `Tests/DispatchKitTests/` (new cases in the existing export/builder suites): trigger raw-value round-trip + unknown-raw fallback to `.manual`; builder stamps the title; v2 round-trip AND absence-tolerance (fixture without the key decodes, title nil).

**Contract:** all new tests written red first, green after; `swift test` fully green; zero app-target changes; pre-existing v2 fixtures untouched and passing (additive proof).

Verify: `swift test`. Commit `feat(kit): journalingSuggestion trigger + report suggestion title (plan 30)` → push.

### Task 2: Kit — JournalingMomentMapper (TDD)

- [ ] **Files:** Create `Sources/DispatchKit/Capture/JournalingMomentMapper.swift` — pure, framework-free: `static func map(title: String, date: DateInterval?, now: Date) -> (overrideDate: Date?, title: String)` implementing the design-decision date rule (interval ended > 30 min before `now` → overrideDate = interval end; ongoing/recent/nil-date → overrideDate nil; the 30-minute grace constant named + documented). Tests first in `Tests/DispatchKitTests/JournalingMomentMapperTests.swift`: past moment backdates to interval END; moment ended 10 min ago files live; ongoing interval (end in future) files live; nil date files live; exact-boundary case pinned.

**Contract:** mapper never imports JournalingSuggestions; deterministic under injected `now`; `swift test` green.

Verify: `swift test`. Commit `feat(kit): journaling moment → survey mapping (plan 30)` → push.

### Task 3: App — survey plumbing carries the suggestion

- [ ] **Files:** Modify `App/Sources/SurveyPresenter.swift` (`SurveyRequest` gains `journalingSuggestionTitle: String?`, doc comment), `App/Sources/ContentView.swift` (pass-through at the `SurveyFlowView` construction site, both idiom branches), `App/Sources/Survey/SurveyFlowView.swift` (property + hand-off to controller; the first-page backdated note mentions the suggestion title when present — "From your suggestion: Morning Run"), `App/Sources/Survey/SurveyController.swift` (store + pass `journalingSuggestionTitle` into `ReportBuilder.save`).

**Contract:** a `SurveyRequest` carrying a title produces a saved `Report` with `journalingSuggestionTitle` set and the correct trigger; requests without one are byte-identical to today (all existing UI tests untouched and green). No new UI surface yet.

Verify: `swift test` + UI suite. Commit `feat: survey flow carries journaling-suggestion context (plan 30)` → push.

### Task 4: App — picker entry point + settings toggle

- [ ] **Files:** Create `App/Sources/Survey/JournalingSuggestionEntryButton.swift` (`import JournalingSuggestions`; wraps `JournalingSuggestionsPicker("From a moment…") { suggestion in ... }`; `onCompletion` destructures `suggestion.title`/`suggestion.date`, runs `JournalingMomentMapper.map`, sets `surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .journalingSuggestion, overrideDate: mapped.overrideDate, journalingSuggestionTitle: mapped.title)`; identifier `journaling-suggestions-button`; doc-cites the picker UX + Catalyst caveat). Modify `App/Sources/HomeView.swift` (mount beside REPORT, gated on the defaults toggle), `App/Sources/Settings/SettingsView.swift` (toggle `journaling-suggestions-toggle`, default OFF, footer per design decision), `App/Sources/Reports/ReportDetailView.swift` (suggestion-title context row near the backdated badge, VoiceOver label "Created from journaling suggestion: …"). UI test additions in `AppUITests/`: button hidden with toggle off, visible after enabling in settings; detail row renders for a seeded report with a title (seeding via the existing test-data path — the picker itself is never presented under test).

**Contract:** framework linked app-target-only (`swift test` proves kit clean); toggle off = zero new UI (default state — full suite green unmodified); toggle on = button present; seeded-report detail row renders with correct a11y label. Build succeeds for iPhone and iPad destinations (iPadOS 26 floor satisfied).

Verify: `swift test` + full UI suite. Commit `feat: Journaling Suggestions picker entry point + settings toggle (plan 30)` → push.

### Task 5: Entitlement request tracking (EXTERNAL — non-blocking)

- [ ] **Track the `com.apple.developer.journal.allow` request** (Robbie submits via the Apple Developer capability-request form — issue #15 says request early; no task above waits on it). When granted: add the entitlement to `App/Dispatch.entitlements` (app target only), enable the capability on the app's bundle-ID resource, regenerate the pinned App Store profiles via the ASC API recipe, archive + `codesign -d --entitlements` prove, flip the `journalingSuggestionsEnabled` default to ON with a release-notes line, then commit — the exact plan-19 device-name / plan-25 CloudDocuments drill. Device-test the picker end-to-end on hardware (first-run system intro sheet, one suggestion of each rough kind: past workout → backdated report at interval end; just-now moment → live capture) and record findings in the completion notes.

### Task 6: Self-review + wrap

- [ ] Re-read the full diff against this plan: schema delta exactly as declared (one optional field, one raw value); no kit import of JournalingSuggestions (grep-prove); no entitlement/profile churn in code tasks; accessibility identifiers stable; comments doc-cited. Run `swift test` + full UI suite one final time. Update this doc with completion notes (including anything the picker's real behavior contradicts — the framework is uncommonly under-documented, log surprises). Rebase on main, open the PR referencing #15 (do NOT close it — the entitlement item stays open until granted).

Verify: full suites green post-rebase. Commit `docs: plan 30 completion notes` → push.
