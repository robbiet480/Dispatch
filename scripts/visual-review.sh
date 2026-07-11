#!/usr/bin/env bash
# VISUAL REVIEW tier — regenerate the themed screenshot set, then print a
# runbook for an agent visual review of the App Store screenshots.
#
#   ./scripts/visual-review.sh
#
# This tier runs pre-release and after any UI-touching change. It does NOT
# re-implement the screenshot rig: it delegates entirely to
# scripts/screenshots.sh (which runs the SCREENSHOT_MODE-gated suites over the
# deterministic --demo-data fixture on each device, cycling app themes, and
# writes docs/app-store/screenshots/). Afterward it prints the review runbook.
#
# See docs/testing-tiers.md and docs/visual-review.md.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="docs/app-store/screenshots"

# (a) Regenerate the themed screenshots by invoking the existing rig.
echo "==> Regenerating screenshots via scripts/screenshots.sh"
./scripts/screenshots.sh

# (b) Print the agent visual-review runbook.
cat <<EOF

============================================================================
VISUAL REVIEW RUNBOOK
============================================================================
Screenshots are in: $OUT_DIR/

Run an agent visual review over every PNG in that directory. For each shot,
and across the set as a whole, check for these defect classes:

  1. COMPOSITION — clipped/cut-off content, misaligned or off-center elements,
     awkward cropping, status-bar/safe-area overlap, inconsistent margins,
     empty or unbalanced whitespace.
  2. COPY — typos, truncated/ellipsized labels, placeholder or lorem text,
     Lorem/demo strings that should not ship, wrong capitalization,
     inconsistent terminology across shots.
  3. CONTRAST — low-contrast text on background, illegible copy in a given
     theme, washed-out or clashing theme palettes, invisible glyphs/icons.
  4. DUPLICATION — two shots that are visually near-identical (same screen,
     same theme) providing no marketing value; a theme used twice where each
     shot is supposed to show a DIFFERENT theme.

Report every finding as: <filename> — <defect class> — <what's wrong>.
If a shot is clean, say so. Re-run this script after any fix.
============================================================================
EOF
