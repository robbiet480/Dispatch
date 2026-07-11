Build 29 (version 1.0) — supersedes 28; use this one.

NEW
- Catalog question configuration (plan 41): submitting a question to the catalog now carries input style, default answer, placeholder, and numeric min/max/step. "Add to my questions" from the catalog copies the submitter's configuration. The submit form shows the same config fields as the question editor.
- Calendar-aware prompts (plan 31): a new prompt-group schedule "When a calendar event ends". Match all events, specific calendars, or titles containing text. Prompts are scheduled ahead from your calendar (EventKit can't wake the app), replanned automatically when your calendar changes. Calendar access is requested in the group editor, only when you pick this schedule.

ALSO
- First macOS companion app build (review/analyze/search/import/export; no capture on Mac). Reports filed on iPhone/watch sync to the Mac through iCloud. Exports: Day One JSON, Markdown folder, Dispatch JSON, CSV. Import accepts Reporter v1 and Dispatch v2 JSON.

WHAT TO TEST
1. Catalog: submit a number question with an input style/default/placeholder — confirm the config survives moderation approval and shows up when another device adds it from the catalog.
2. Prompt Groups: create a "When a calendar event ends" group matching a test calendar, create an event ending a few minutes out, lock the phone — confirm the prompt arrives at event end and the report shows the calendar trigger.
3. Edit/delete calendar events and confirm prompts reschedule (open the app once after editing).
4. Calendar permission flows: deny access → group editor shows the Settings hint; grant → hint clears.
