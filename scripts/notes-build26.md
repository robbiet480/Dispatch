Build 26 (version 1.0) — supersedes 25; use this one.

CHANGED
- Sensor permissions now live in the row's on/off slider itself, no separate status. If the app doesn't have permission yet, the slider is off and greyed with a "Request" button beside it; if you denied it, a "Settings" button (tap to fix — iOS only lets you reverse a denial there). Once granted, the slider just works. Note: Apple hides whether you granted Health *read* access, so those rows can't show more than "asked and usable" — the free slider means Dispatch can use it.

DIAGNOSTIC (temporary — for me)
- Settings > Sensors > Diagnostics > "Sleep Delivery Probe": turn on, sleep with the watch, and it logs how long HealthKit takes to deliver sleep samples to Files > Dispatch > sleep-probe.log. Feeds the auto awake/asleep design; removed after measurement.

WHAT TO TEST
1. Settings > Sensors: granted sensors show a working slider; ungranted ones show Request; denied ones show Settings.
2. Enable the Sleep Delivery Probe, then add a manual sleep entry in Health (instant control) or wear the watch overnight, and check sleep-probe.log.
