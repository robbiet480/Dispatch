Build 33 (version 1.0) — supersedes 32; use this one. One important sync fix.

FIXES
- iCloud sync loop: a background maintenance pass was re-running every couple of seconds, continuously rewriting your saved words/people and thrashing the iCloud export. On some accounts this stopped data from ever reaching another device (e.g. the Mac app showing nothing) and drained battery in the background. Sync now settles quietly and stays put.

WHAT TO TEST
1. Cross-device sync: open Dispatch on your iPhone and on a second device (Mac or iPad) signed into the same iCloud account. Confirm your questions, reports, and history show up on both. If your Mac previously showed no data, update EVERY device to build 33, open the app on each, and give iCloud a minute to catch up — the Mac should populate.
2. Diagnostics look quiet: Settings → iCloud → Diagnostics. The EVENTS list should no longer fill with a "Dedupe pass" every couple of seconds — it should stay quiet unless something actually changed, and "Last iCloud export" should read succeeded (not failed).
3. Everyday use unchanged: filing reports, Prompt Groups, and check-ins should behave exactly as before.
