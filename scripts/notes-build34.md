Build 34 (version 1.0) — supersedes 33; use this one. The big one: iPad gets a redesigned layout, plus safer data handling.

NEW
- iPad redesign: iPad now uses a proper split-view layout that matches the Mac — a top bar to switch between Dashboard, Insights, Questions, Prompt Groups, and the Question Catalog, with the list on the left and detail on the right instead of pushing screen-to-screen. The Dashboard keeps its REPORT button and the Awake/Asleep toggle.
- Question Catalog is now a shared, side-by-side browser on iPad (and iPhone pushes to it as before): pick a suggested question on the left, see its full prompt and a non-interactive preview of how it'll look on the right, before adding it.
- iPhone Settings reorganized: the management screens (Questions, Prompt Groups, Catalog) are grouped under a clearer "Manage" section.

FIXES
- Delete All Data is safer and more honest. The wipe and the restore-default-questions step are now a single operation, so a failure can't leave you with your data gone AND no questions. If you also chose to delete backups, the app now waits for that to actually finish and tells you the truth — including a clear, separate message if your data was deleted but iCloud backups couldn't be reached (e.g. signed out of iCloud). Previously some of these outcomes showed under the wrong title.

WHAT TO TEST
1. iPad layout: on an iPad, open Dispatch and use the top bar to move between Dashboard, Insights, Questions, Prompt Groups, and Catalog. Confirm the list/detail split feels right in both portrait and landscape, that selecting an item shows it on the right, and that the Dashboard still has the REPORT button and the Awake/Asleep toggle. Filing a report and editing a question should work as before.
2. Question Catalog: open Catalog, pick a suggested question, and confirm the right side shows its prompt and a preview. Add one and confirm it appears in your Questions. On iPhone, confirm Catalog still opens as a full screen you can back out of.
3. iPhone Settings: confirm Questions / Prompt Groups / Catalog are reachable under the "Manage" grouping and each opens correctly.
4. Everyday use unchanged on iPhone: filing reports, check-ins, Prompt Groups, and sync should behave exactly as before — this build's iPhone changes are mostly organizational.
5. (Optional, destructive — only on a test device) Delete All Data: Settings → Data → Delete All Data. Confirm the confirmation gates behave, and after confirming, the app resets to the default questions cleanly. Do NOT do this on a device with data you want to keep.
