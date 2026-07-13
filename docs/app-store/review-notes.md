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
with their own questionnaire and attaches sensor context to each answer.
No Dispatch account exists; no demo credentials are needed. Spotify
sign-in is optional and required only if the user chooses to connect
Spotify for now-playing detection. Universal app (iPhone, iPad, Apple
Watch, Mac) synced through the user's iCloud; the Mac only reviews and
manages (no sensors, no prompts).

QUICK DEMO PATH: finish onboarding (permissions asked in context,
deniable), tap REPORT, answer, tap DONE. Settings → Data has export
(JSON/CSV), backups, and Delete All Data.

PERMISSIONS, ONE BY ONE
- Notifications: randomly timed survey prompts (the core mechanic);
  "nag" re-reminders are Time Sensitive notifications.
- Location (When in Use): stamps the report location (with speed,
  heading, altitude) and fetches weather via WeatherKit.
- Location (Always): asked contextually only when a prompt group uses a
  location trigger — arriving somewhere new (CLVisit), or entering /
  leaving a picked place or iBeacon (CLMonitor). Never at onboarding. On
  Mac, used once for "Use current location" when setting up a place.
- Calendar (full access): read only to fire a group when a matching
  event ends; event details never leave the device.
- Health (read): steps, heart rate, HRV, sleep, workouts, Activity rings
  — a per-report snapshot stored with the report (syncs to private iCloud
  if sync is on, per the privacy policy).
- Health medications (separate per-object authorization, its own step):
  shows dose events the user already logged. No medical advice.
- Health (write): State of Mind only, for questions marked to log mood.
- Media & Apple Music: reads the currently-playing song, artist, and
  album; never any audio.
- Microphone: sampled to a single decibel number per report; no audio is
  recorded or stored.
- Photos: counts photos taken since the last report and stores documented
  metadata (dimensions, timestamps, location); images themselves are never
  read or uploaded.
- Motion & Fitness: stairs descended, to pair with Health's flights.
- Face ID: optional app lock.
- Focus status: whether a Focus was active at filing; an optional Focus
  Filter can mute chosen prompt groups.
- Contacts (OPTIONAL, default off; Settings → Sensors → "Suggest from
  Contacts"): matches names on device for chips; the link cache is
  device-local, photos live-fetched, never stored.
- Local Network: only if the opt-in webhook is configured; plain HTTP is
  limited to local-network hosts.

SPOTIFY (optional, opt-in)
Settings → Sensors → Spotify → Connect runs a Spotify OAuth
(app-remote-control scope) via Spotify's official App Remote SDK. A
connected report can note the currently-playing track; the app stores
only a Keychain access token and reads now-playing. No data goes to us,
an ad network, or a data broker. Disconnect deletes the token.

ICLOUD
Data syncs via SwiftData's CloudKit mirroring to the user's own private
CloudKit database (Settings → Data → iCloud turns it off). Backups write
to the Files app and optionally the user's iCloud Drive. Delete All Data
propagates erasure to iCloud. No synced data reaches the developer.

BACKGROUND MODES
remote-notification only (CloudKit silent pushes). Trigger groups relaunch
via HealthKit background delivery, EventKit, CLVisit, and CLMonitor — no
location background mode.

WEBHOOKS (opt-in, user-directed)
Off by default; sends the user's report JSON to the one endpoint they
entered; we run no server and receive nothing. HTTPS is required for
non-local endpoints; optional HMAC signing and AES-256-GCM encryption via
OS CryptoKit (ITSAppUsesNonExemptEncryption = NO).

COMMUNITY CATALOG (user-generated content)
Settings → Questions → Catalog browses shared question sets (public
CloudKit DB). Submissions include question text plus an opaque CloudKit
creator identifier for moderation (not the user's name, email, or Apple
ID); submissions are held for moderation before appearing and can be
reported/removed.

ORIGIN
Original, open-source (MIT) app inspired by Reporter (Nicholas Felton,
2014, discontinued). No original Reporter code/assets/branding; imports
Reporter's JSON export so users keep their history. Source:
github.com/robbiet480/Dispatch
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
