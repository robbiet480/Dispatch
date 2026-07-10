Build 28 (version 1.0) — supersedes 27; use this one.

NEW
- Sync diagnostics (Settings > iCloud > Sync Diagnostics): a privacy-safe screen showing recent sync events (newest first), lifetime dedupe merge counts, and per-device report provenance. A ShareLink exports a plain-text dump for bug reports — it contains app/OS/device identifiers and sync provenance ONLY, never report content, answers, prompts, vocabulary, or health data.
- Configurable digest schedules (Settings > Notifications): the old fixed Sunday-7pm weekly digest is now fully configurable — weekly / monthly / quarterly, each with its own day and time. Monthly clamps to month-end (a "31st" digest fires Feb 28/29). Multiple schedules can run at once; a tapped reminder opens the digest scoped to that period.

FIXED
- Time-question answers could crash the app on CSV export / anywhere a saved time answer was read (a SwiftData storage bug in the plan-28 time question). Now stored safely; existing time answers are unaffected.

WHAT TO TEST
1. Settings > iCloud > Sync Diagnostics: confirm events list reads newest-first, and the shared text dump has no personal report content.
2. Settings > Notifications: create weekly/monthly/quarterly digest schedules, confirm they persist and (if you can wait for one) fire with the right period copy.
3. Add a Time question, answer it, then export CSV (Settings > Data) — confirm no crash and the time + "(day offset)" columns are present.
