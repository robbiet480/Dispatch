# Dispatch Plan 23: App Store prep

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** everything between "great TestFlight app" and "on the App Store": a current README, fully automated App Store screenshots, a defensive review-readiness analysis with a risk register, and the complete listing kit (privacy policy, description/keywords, privacy-label answers, reviewer notes).

**Architecture:** screenshots via the existing XCUITest harness (XCTAttachment full-screen captures over seeded demo data, extracted from the xcresult by a script — no fastlane dependency). Review analysis is research + codebase audit producing a living risk document. Listing artifacts live in `docs/app-store/`.

## Global Constraints

- No new entitlements; nothing in this plan changes app behavior except the `--demo-data` seeding path (test-gated like every launch arg). Suites green per commit; scoped commits + push (standing instruction). Do NOT bump the build number.
- This is a PERSONAL app (not CampusGroup): personal hosting choices only (GitHub Pages on the repo for the privacy policy).

---

### Task 1: Defensive review-readiness analysis (read-only; can run first/parallel)

**Files:** Create `docs/app-store/review-readiness.md`.

**Contract:** research the CURRENT App Store Review Guidelines (fetch, don't recall — guideline numbers and text change) and audit the codebase against them. Mandatory investigation list:
- **HealthKit data in iCloud (the big one):** find the current guideline text (historically 5.1.3-adjacent: apps may not store health information in iCloud) and determine precisely whether CloudKit-synced Report health readings (steps, HR, workouts, rings, MEDICATIONS) violate it. If yes: propose concrete mitigations with effort estimates (e.g. health readings become a local-only non-synced sidecar model; or a sync-exclusion for health fields with re-capture-on-device semantics; or user-consent framing if any precedent exists). This finding gates the launch plan.
- HealthKit purpose/usage compliance (2.5.1, 5.1.3): readings used only for user display; medications especially (sensitive class).
- Always-location justification (visit triggers): reviewer-facing explanation + the in-app contextual ask (good story, document it).
- Contacts usage framing; Face ID; microphone (dB only, no recording — purpose string already says so).
- Privacy nutrition label truthfulness vs actual data flows (CloudKit private DB = "data linked to you"? research the label taxonomy).
- Background modes justification (remote-notification for CloudKit).
- 4.2 minimum functionality / 4.1 copycat risk: Dispatch is a clone-with-attribution of a discontinued app — assess and draft the "inspired by Reporter, original code, original assets" defense; verify no residual Reporter assets/copy in the repo (audit onboarding strings).
- Account/data rules: no accounts (5.1.1(v) n/a), data deletion (export + delete all? check if a delete-all exists; if not, note as gap), kids/age rating inputs.
- Encryption/export compliance (ITSAppUsesNonExemptEncryption already NO — confirm still accurate with CloudKit).
Output: risk register table (guideline → finding → severity → mitigation → owner), top-3 blockers called out, recommended submission sequencing. Cite guideline URLs.

Verify: doc exists, cited, no recalled-guideline claims. Commit `docs: app store review-readiness analysis` → push.

### Task 2: README overhaul

**Files:** Modify `README.md`; create `docs/app-store/` screenshot placeholders section when Task 3's output lands.

**Contract:** rewrite to current reality: full feature list (parity + prompt groups incl. timed/workout/visit/focus triggers, nags, sync, widgets/Control Center, digest, insights-if-shipped, backups, medications, person identity-if-shipped — check the actual shipped state at execution time), architecture section (DispatchKit/app split, XcodeGen, test counts), building-from-source (portal prerequisites: WeatherKit, iCloud container, push — the fork checklist), release pipeline note, contribution pointers, screenshots section fed by Task 3, credit to Reporter as inspiration (defense-aligned wording from Task 1). Honest, not marketing-fluffed.

Verify: builds/instructions spot-checked against project.yml reality. Commit `docs: README overhaul for current feature set` → push.

### Task 3: Automated App Store screenshots

**Files:** Create `AppUITests/ScreenshotTests.swift`, `App/Sources/` demo-data seeding behind `--demo-data` (curated fixture: ~30 realistic reports across 2 weeks, pretty viz data, a prompt group, digest-ready), `scripts/screenshots.sh`.

**Contract:**
- `--demo-data` (test-environment-gated like all args): seeds the in-memory store with the curated fixture — deterministic, visually rich (varied tokens/people/places, numeric trends for graphs, workout + rings data mocked at the provider layer as the UI tests already do).
- `ScreenshotTests`: navigates and captures (XCTAttachment, full-screen, `.keepAlways`) the money shots: home viz page (proportion bands), a report detail, survey with capture checklist + a question, prompt groups editor, weekly digest (template path), widget gallery can't be automated — note it; capture Settings→People/Backups as bonus.
- `scripts/screenshots.sh`: runs the screenshot tests on the App-Store-required simulators (current 6.9" and 6.5" device classes — verify the CURRENT required sizes from Apple's screenshot specifications page at execution time, don't recall), extracts PNGs from the xcresult (`xcrun xcresulttool`), names them `<device>-<nn>-<name>.png` into `docs/app-store/screenshots/` (gitignored except a README row of thumbnails if size-reasonable). Idempotent, one command.
- Suites unaffected (screenshot tests in their own test plan/class, excluded from the default UI suite run — verify CI stays green and fast).

Verify: script produces the full set locally; suites green. Commit `feat: automated App Store screenshots` → push.

### Task 4: Listing kit + wrap

**Files:** Create `docs/app-store/listing.md` (name/subtitle/description/keywords/what's-new draft, category, age-rating answers), `docs/app-store/privacy-labels.md` (nutrition-label answer sheet mapped to actual data flows, informed by Task 1), `docs/privacy-policy.md` (the actual policy: on-device data, user's private iCloud, no third-party services, no analytics, WeatherKit/Apple services disclosure; plus GitHub Pages hosting instructions — personal repo, one settings toggle), `docs/app-store/review-notes.md` (the permission walkthrough for the reviewer incl. the Always-location and medications stories, demo instructions).

**Contract:** listing copy honest and specific (no superlatives that trip 2.3.1 metadata rules — Task 1 informs); privacy labels must match the policy must match the code (three-way consistency check documented). Wrap: completion note; flag any Task-1 blockers still open as the launch gate.

Verify: docs complete, three-way consistency stated. Commit `docs: app store listing kit + privacy policy` → push. Whole-branch review follows (controller-driven) — review focuses on truthfulness vs the codebase, not code.
