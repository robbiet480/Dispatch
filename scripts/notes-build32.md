Build 32 (version 1.0) — supersedes 31; use this one. Mostly fixes from tester feedback.

NEW
- Random Check-ins can now be turned off (Settings → Notifications → "Random Check-ins"). Turn it off if you only want your Prompt Groups to notify you — your groups keep firing on their own schedules; the app's random "What are you up to?" prompts stop entirely. On by default, so nothing changes unless you switch it off.
- A "View on GitHub" link at the bottom of Settings (the app is open source).

FIXES
- Apple Watch quick-answer: the default open-text prompt ("What are you up to right now?") was wrongly showing Yes/No buttons that did nothing. Yes/No now appears only for actual yes/no questions and files the answer when tapped; open-text prompts just open the app (with a Snooze option).

WHAT TO TEST
1. Random Check-ins toggle: Settings → Notifications → turn "Random Check-ins" OFF. Confirm you stop getting the random "What are you up to?" prompts, but a Prompt Group (e.g. a timed group) still fires. Turn it back ON and confirm the randoms resume. (Existing setup should be unchanged until you touch the toggle.)
2. Watch notifications: for the default/open-text prompt, confirm the watch shows no Yes/No (just tap-to-open + Snooze). For a yes/no question, confirm the watch shows Yes/No and tapping one actually saves the answer (check it lands on your phone).
3. Bottom of Settings → "View on GitHub" opens the repository.
