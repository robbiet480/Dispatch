# Visual review tier

The third testing tier (see [testing-tiers.md](testing-tiers.md)). It is a
**local / manual** gate — not part of CI.

## When it runs

- Before every release / TestFlight upload.
- After any change that touches UI, layout, theming, or on-screen copy.

## Steps

1. Run `scripts/visual-review.sh`. It delegates to `scripts/screenshots.sh`,
   which regenerates the themed screenshot set over the deterministic
   `--demo-data` fixture on each device (iPhone / iPad / watch / Mac), cycling
   app themes per shot, into `docs/app-store/screenshots/`.
2. The script then prints a runbook. Run an agent visual review over every PNG
   in `docs/app-store/screenshots/`, checking each shot and the set as a whole
   for these defect classes:
   - **Composition** — clipped content, misalignment, awkward crop, safe-area
     overlap, inconsistent margins/whitespace.
   - **Copy** — typos, truncated labels, placeholder/demo strings, wrong
     capitalization, inconsistent terminology.
   - **Contrast** — low-contrast or illegible text, washed-out or clashing
     theme palettes, invisible glyphs.
   - **Duplication** — near-identical shots with no marketing value; a theme
     reused where each shot should show a different theme.
3. Report findings as `<filename> — <defect class> — <what's wrong>`, fix, and
   re-run the script.
