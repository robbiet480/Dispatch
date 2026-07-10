Build 27 (version 1.0) — supersedes 25/26; use this one.

CHANGED
- Settings > Sensors is now grouped into categories — Health, Location & Weather, Device, Media & Surroundings — each sorted alphabetically, instead of one long list.
- Sensor permissions live in the row's on/off slider: no permission yet = off + greyed with a "Request" button; denied = "Settings" button (tap to fix); granted = the slider just works. (Apple hides whether you granted Health *read* access, so those rows can't show more than "usable.")

DIAGNOSTIC (temporary — for me)
- Settings > Sensors > Diagnostics > "Sleep Delivery Probe": turn on, sleep with the watch, and it logs HealthKit sleep-sample delivery timing to Files > Dispatch > sleep-probe.log. Feeds the auto awake/asleep design; removed after measurement.

WHAT TO TEST
1. Settings > Sensors: confirm the categories/sorting read well, and the sliders reflect real permission state.
2. Enable the Sleep Delivery Probe, then add a manual sleep entry in Health (instant control) or wear the watch overnight, and check sleep-probe.log.
