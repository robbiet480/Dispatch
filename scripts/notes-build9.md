Build 9 — hotfix for the build 8 launch crash.

FIXED
- Crash on first launch after updating (a race in the new Motion permission request could crash the app during the one-time permission top-up, and then repeat on every launch). Two more latent crashes of the same kind fixed preemptively (Focus permission request, staircase reader).
- The one-time permission top-up now only ever attempts once; if you don't get the Motion/Medications prompts, use Settings > Sensors > Request Sensor Access.

EVERYTHING FROM BUILD 8 STILL APPLIES
- Widgets + Control Center button, Weekly Digest, medications capture, staircases down, background iCloud sync, data store migration.
- If build 8 crashed for you on launch: install this build, launch, and expect the Motion/Medications permission prompts once. Then run through the build 8 test list.
