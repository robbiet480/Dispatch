Build 23 (version 1.0) — includes everything from build 22, notes below cover both.

NEW IN 23
- Tap the song on a report to open it in Apple Music or Spotify. Track links are also included in exports and webhook payloads now.
- Home charts are truly edge-to-edge on iPhone — no more margin halo around the blocks.
- Backups grew up: each device backs up under its own name (no more overwriting each other), backup files record which device wrote them and when, and a fresh install waits for sync to settle before its first automatic backup. Plus a Back Up Now button right in iCloud settings.

FIXED IN 23
- Alerts per Day and the reminder steppers actually respond to taps now (the row was swallowing them — both buttons fired at once, canceling out).
- "ADD A NOTIFICATION TIME" no longer shouts; it's a normal action row.

FROM BUILD 22 (if you skipped it)
- THE REPORTER HOME SCREEN: full-bleed stacked charts with in-block labels, uppercase question heading, plain page dots, and an AWAKE pill toggle — the original's layout, structurally overlap-proof.
- MEDIA + CONNECTION: reports capture what you're listening to (Apple Music automatic, Spotify via Settings > Sensors > Connect), and the connection sensor knows 5G/LTE/3G/2G/Wired/Satellite.
- Sensors settings show real per-permission status (Granted / Request / Denied→Settings); Request All hides when there's nothing to ask.
- Fixed black-on-teal text in the editors, the Spotify-return lock trap, first-launch notification churn, and first-run iCloud backup failures.

WHAT TO TEST
1. Tap a report's song row — should land on the track in the right app.
2. Home: confirm charts touch the screen edges and nothing clips in the corners, every theme.
3. Change Alerts per Day and the reminder steppers — they work now.
4. Check the iCloud Drive Backups folder from two devices — each device keeps its own files.
