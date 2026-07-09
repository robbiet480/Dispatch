Build 13

NEW: ARRIVAL PROMPTS
- Prompt Groups can now trigger "When I arrive somewhere" — Dispatch notices when you arrive at a place and asks that group's questions. Setting one up asks for Always location access (needed so iOS can wake Dispatch when you arrive; the report explains this in the editor).

NEW: AUTOMATIC BACKUPS
- Dispatch now keeps rotating daily backups of your full export (newest 14) — visible in the Files app under On My iPhone > Dispatch > Backups. Settings > Data has a Back Up Now button. Reminder: sync is not backup — this is your safety net.

ALSO
- Zero-warning codebase cleanup under the hood.

WHAT TO TEST
1. Create a prompt group with the "When I arrive somewhere" schedule, grant Always location, then go somewhere and linger a few minutes — you should get that group's prompt (iOS visit detection can take several minutes after arrival; it is not instant).
2. Settings > Data > Back Up Now, then check Files > On My iPhone > Dispatch > Backups.
