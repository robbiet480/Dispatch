Build 31 (version 1.0) — supersedes 30; use this one.

NEW
- Place triggers by name or address (plan 50): create a "when I arrive at / leave a place" prompt group by typing a place name or address with autocomplete — no more entering raw coordinates. Or tap "Use my current location" to drop the trigger where you are. Works on iPhone and Mac, and the Mac can now create place-triggered groups (previously it could only view them). iPhone keeps a manual coordinate entry behind an "advanced" disclosure.

FIXES
- Fixed a crash on macOS when opening the Question Catalog (regression in build 30): the catalog's search moved out of the window toolbar into the view, so it no longer collides with the reports sidebar's search. Opening the Catalog is safe again.

WHAT TO TEST
1. Place trigger by search: Prompt Groups → new group → "When I arrive at / leave a place" → type an address or place name, pick a suggestion, save. Confirm the group monitors that location and fires on arrival/departure. Try the "leave" direction too.
2. Use current location: in the place editor, tap "Use current location", grant location when asked — confirm it fills in your current spot (test on both iPhone and Mac).
3. Mac catalog: on the Mac, open the Question Catalog — confirm it opens and renders (no crash) and that searching the catalog still works.
4. Mac place group: on the Mac, create a "when I arrive at / leave a place" group via search — confirm it saves and appears in the groups list (this is new — the Mac couldn't create these before).
5. iPhone advanced entry: confirm the manual latitude/longitude fields are still reachable under the place editor's advanced disclosure and still work.
