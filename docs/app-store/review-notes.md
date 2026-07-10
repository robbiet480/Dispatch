# Dispatch — Notes for Review (App Store Connect)

*Plan 23, Task 4. Paste into ASC → App Review Information → Notes.
Written to satisfy 2.3.1's "describe with specificity" bar: every
permission and how to trigger it, described factually — no
editorializing about guideline risk. Kept under ASC's 4000-character
notes limit — `asc-listing.swift` uploads this block verbatim and
truncates anything over the cap, so check the length after editing.*

## Paste-ready reviewer notes

```
Dispatch is a self-tracking app: it prompts the user a few times a day
with their own short questionnaire and attaches sensor context to each
answer. No account or sign-in exists; no demo credentials are needed.

QUICK DEMO PATH: complete onboarding (every permission is asked in
context and can be denied; the app still works), tap REPORT, answer,
tap DONE — the first survey page lists the sensors being captured.
After 2-3 reports the home screen fills with charts. Settings → Data
has export (JSON/CSV), automatic backups, and Delete All Data.

PERMISSIONS, ONE BY ONE
- Notifications: the core mechanic — randomly timed survey prompts.
  Optional "nag" re-reminders use Time Sensitive notifications.
- Location (When in Use): stamps the report location and fetches
  weather via Apple's WeatherKit.
- Location (ALWAYS — requested ONLY in one place): Settings → Prompt
  Groups → New Group → "When I arrive somewhere", which uses Apple's
  power-efficient CLVisit monitoring. Asked contextually at that
  moment, never at onboarding; if declined, only that group type is
  unavailable. Purpose string states this scope.
- Health (read): steps, flights, heart rate, HRV, resting HR, sleep,
  workouts, caffeine, Activity rings — a snapshot per report for the
  user's own review. Displayed only; no advertising, no third parties
  (no analytics, no SDKs, no server of ours).
- Health medications (separate per-object authorization, its own
  explanation step): shows dose events the user already logged in
  Health. No medical advice is given.
- Health (write): State of Mind only, for questions the user marks to
  log mood.
- Microphone: sampled to a single decibel number per report; no audio
  is ever recorded or stored.
- Photos: counts photos taken since the last report; images are never
  read, copied, or uploaded.
- Motion & Fitness: stairs descended, to pair with Health's flights.
- Face ID: optional app lock.
- Focus status: whether a Focus was active at filing; an optional
  Focus Filter can mute chosen prompt groups.
- Contacts (OPTIONAL, default off; asked only at Settings → Sensors →
  "Suggest from Contacts"): matches names on device for name/photo
  chips. Matching and the link cache are device-local; photos are
  live-fetched, never stored; nothing from Contacts leaves the device.
- Local Network: only if the opt-in webhook is configured; plain HTTP
  is limited to local-network hosts.

ICLOUD
Data syncs via SwiftData's CloudKit mirroring to the user's own
private CloudKit database (Settings → Data → iCloud turns it off).
Automatic backups write to the local Files app and, optionally, the
user's own iCloud Drive. Delete All Data propagates erasure to iCloud.
No data is ever accessible to the developer or any third party.

BACKGROUND MODES
remote-notification only (CloudKit silent pushes). Workout-end and
visit-arrival triggers use HealthKit background delivery and CLVisit
relaunches (no location background mode).

WEBHOOKS (opt-in, user-directed)
Off by default; sends the user's own report JSON from the device to
the single endpoint they entered. We operate no server and receive
nothing. HTTPS required for non-local endpoints; optional HMAC signing
and AES-256-GCM encryption via OS CryptoKit (consistent with
ITSAppUsesNonExemptEncryption = NO).

COMMUNITY CATALOG (user-generated content)
Settings → Questions → Catalog browses shared question sets from a
public CloudKit database. Submissions contain only question text, are
held for moderation before appearing, and can be reported/removed.

ORIGIN
Original, open-source (MIT) implementation inspired by Reporter
(Nicholas Felton, 2014, discontinued). No original Reporter code,
assets, or branding; imports Reporter's documented JSON export so
former users keep their history. Source: github.com/robbiet480/Dispatch
```

## Internal reminders (do not paste)

- Confirm the archive's entitlements before submitting:
  `aps-environment` must read `production` in the exported IPA
  (`codesign -d --entitlements - <app>`), per review-readiness §2.9.
- Contact info fields in ASC: personal email/phone (this is a personal
  app — nothing @campus.edu).
- If the reviewer rejects on 5.1.3(ii), respond with the
  snapshot/private-DB framing in review-readiness.md §1 (step 2 of the
  accepted-risk escalation ladder) before building the sidecar
  fallback.
- Catalog moderation must be responsive during review week: run
  `swift run dispatch-mod dashboard` daily so a reviewer-submitted
  question set doesn't sit unmoderated.
