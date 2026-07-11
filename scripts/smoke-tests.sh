#!/usr/bin/env bash
# SMOKE tier — the per-merge UI-test gate (target ~3-4 min).
#
#   ./scripts/smoke-tests.sh
#
# Runs ONLY the smoke-tier UI tests in a single `xcodebuild test` invocation
# using repeated `-only-testing:` selectors. These few tests are the fast,
# high-signal subset a human runs (or an agent runs) before merging — enough
# to catch a broken survey flow, navigation, app-lock gate, data reset, the
# core layout, or the sync-diagnostics screen without paying for the whole
# suite.
#
# The FULL suite is the nightly / pre-release tier: run the ENTIRE UI-test
# target instead — same invocation WITHOUT any `-only-testing:` flags, e.g.
#
#   xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp \
#     -destination "$DESTINATION"
#
# plus `swift test` for the DispatchKit unit suite. See docs/testing-tiers.md.
#
# NOTE: CI (.github/workflows/ci.yml) runs ONLY `swift test` + an app build —
# it does NOT run these UI tiers. Smoke/full/visual are a LOCAL/manual gate.
#
# Destination defaults to a stock iPhone simulator; override with the
# SMOKE_DESTINATION env var (same syntax as scripts/screenshots.sh), e.g.
#   SMOKE_DESTINATION="platform=iOS Simulator,name=iPhone 17" ./scripts/smoke-tests.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# xcodegen-generate-if-needed (matches screenshots.sh / upload-testflight.sh).
if ! [ -d Dispatch.xcodeproj ]; then
  xcodegen generate
fi

DESTINATION="${SMOKE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
DERIVED_DATA="${SMOKE_DERIVED_DATA:-build/DerivedData-smoke}"

# Smoke-tier selectors. UI-test target is `DispatchUITests` (verified in
# project.yml — sources: [AppUITests], TEST_TARGET_NAME: DispatchApp).
#   - SurveyFlow (2): core capture path + pending-text flush edge case.
#   - Navigation: tab/nav + awake toggle.
#   - DeleteAllData: destructive reset + default-question reseed.
#   - AppLock: the lock gate that guards Home.
#   - HomeParity: the one layout smoke (top bar glyph + filter row).
#   - SyncDiagnostics: whole class (single test) via class-level selector.
xcodebuild test \
  -project Dispatch.xcodeproj \
  -scheme DispatchApp \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:DispatchUITests/SurveyFlowUITests/testCompleteReportFlowSavesReport \
  -only-testing:DispatchUITests/SurveyFlowUITests/testImmediateDoneAfterTypingFlushesPendingText \
  -only-testing:DispatchUITests/NavigationUITests/testNavigationAndAwakeToggle \
  -only-testing:DispatchUITests/DeleteAllDataUITests/testDeleteAllDataResetsReportsAndReseedsDefaultQuestions \
  -only-testing:DispatchUITests/AppLockUITests/testAppLockGatesHomeUntilUnlocked \
  -only-testing:DispatchUITests/HomeParityUITests/testTopBarGlyphAndLeftAlignedFilterRow \
  -only-testing:DispatchUITests/SyncDiagnosticsUITests

echo "==> Smoke tier passed."
