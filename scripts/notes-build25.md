Build 25 (version 1.0)

CHANGED
- Sensor permission rows now show a filled/empty radio instead of a text status. Filled = the app can use that sensor; empty = it can't yet (with a Request button) or you denied it (tap to open Settings). This replaces the confusing "Requested" label that stuck around on Health rows — Apple deliberately hides whether you granted Health *read* access, so once asked, the app genuinely can't tell granted from denied; the filled radio just means "we've asked and it's usable."

DIAGNOSTIC (temporary — for me)
- Settings > Sensors > Diagnostics has a "Sleep Delivery Probe" toggle. Turn it on, sleep with the watch, and it logs how long HealthKit takes to deliver sleep samples to Files > Dispatch > sleep-probe.log. Feeds the auto awake/asleep design. Will be removed after measurement.

WHAT TO TEST
1. Settings > Sensors: confirm the radios match reality — granted Health items show filled.
2. Enable the Sleep Delivery Probe, then either add a manual sleep entry in Health (instant control) or wear the watch overnight, and check sleep-probe.log in the morning.
