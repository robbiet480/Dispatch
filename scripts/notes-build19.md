Build 19

FIXED
- Dark mode: black bands behind footer text on every settings screen (Notifications, Sensors, Data, Webhooks, and more) — swept all 21 of them.
- Home charts no longer hide behind the page dots — the yes/no bottom row and chart gridlines now clear the indicator on every page type.
- Notifications screen: the big "—" over FROM DISTRIBUTION now actually tells you something. You'll see the next prompt time with its real source (distribution / scheduled time / group), or an honest empty state — including "notifications are off" and "prompts resume at wake." Nag reminders no longer masquerade as the next prompt.

WHAT TO TEST
1. Dark mode: skim every settings screen's footer text — no black bands anywhere.
2. Home: swipe all visualization pages — nothing hidden behind the dots.
3. Notifications screen at different times: check the NEXT NOTIFICATION section always makes sense (with prompts pending, with none, while asleep).
