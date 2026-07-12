# Testing tiers

Dispatch runs its tests in three tiers. **CI (`.github/workflows/ci.yml`) runs
only `swift test` (the DispatchKit unit suite) + an app build — it does NOT run
the UI tiers.** SMOKE, FULL, and VISUAL REVIEW below are a **local / manual**
process gated by a human (or an agent) before merge and before release.

Heavy CI jobs run on self-hosted M4 minis — see [selfhosted-runners.md](selfhosted-runners.md).

## 1. SMOKE — per-merge (~3-4 min)

- **Run:** `scripts/smoke-tests.sh`
- **What:** a single `xcodebuild test` over the fast, high-signal subset of the
  `DispatchUITests` target (scheme `DispatchApp`). Destination overridable via
  `SMOKE_DESTINATION`.
- **When:** before every merge to `main`.
- **Tests, and why each is representative:**
  - `SurveyFlowUITests/testCompleteReportFlowSavesReport` — the core capture
    path (open survey → answer → save → persisted report). If this breaks the
    app is unusable.
  - `SurveyFlowUITests/testImmediateDoneAfterTypingFlushesPendingText` — the
    pending-text flush edge case (tapping Done mid-type must not drop input).
  - `NavigationUITests/testNavigationAndAwakeToggle` — top-level navigation +
    the awake/asleep toggle wiring.
  - `DeleteAllDataUITests/testDeleteAllDataResetsReportsAndReseedsDefaultQuestions`
    — the destructive reset path and default-question reseed.
  - `AppLockUITests/testAppLockGatesHomeUntilUnlocked` — the lock gate that
    must guard Home before unlock.
  - `HomeParityUITests/testTopBarGlyphAndLeftAlignedFilterRow` — the one layout
    smoke (top-bar glyph + left-aligned filter row).
  - `SyncDiagnosticsUITests` (whole class, one test:
    `testDiagnosticsScreenReachableWithExportButton`) — the diagnostics screen
    is reachable and exposes its export button.

## 2. FULL — nightly / pre-release (the current merge gate)

- **Run:** the ENTIRE `DispatchUITests` target + the unit suite:
  ```sh
  xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro Max"
  swift test
  ```
  (omit `-only-testing:` — that is exactly what makes it the full tier).
- **What:** every UI test plus `swift test` (DispatchKit).
- **When:** nightly and before every release / TestFlight upload.

## 3. VISUAL REVIEW — pre-release / after UI-touching changes

- **Run:** `scripts/visual-review.sh`
- **What:** regenerates the themed App Store screenshot set via
  `scripts/screenshots.sh`, then prints a runbook for an agent visual review of
  `docs/app-store/screenshots/` (composition, copy, contrast, duplication).
- **When:** before release, and after any change that touches UI/layout/copy.
- See [visual-review.md](visual-review.md) for the full runbook.
