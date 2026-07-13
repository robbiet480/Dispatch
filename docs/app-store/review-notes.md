# Dispatch — Notes for Review (App Store Connect)

*Paste the matching block into ASC → App Review Information → Notes.
Written to satisfy 2.3.1's "describe with specificity" bar: every
permission and how to trigger it, factually. ASC caps notes at 4000
characters — both blocks are kept under with margin (`asc-listing.swift`
uploads the iOS block verbatim and truncates over the cap, so re-check the
length after editing).*

## Paste-ready reviewer notes

*(iOS / iPadOS / watchOS — the `io.robbie.Dispatch` app record.)*

```
Dispatch is a self-tracking app: it prompts the user a few times a day
with their own questionnaire and attaches sensor context to each answer.
No account, sign-in, or demo credentials (Spotify is optional, only if the
user connects it for now-playing). Universal app (iPhone, iPad, Apple
Watch, Mac) synced through iCloud; the Mac only reviews and manages.

QUICK DEMO: finish onboarding (permissions asked in context, deniable),
then REPORT → answer → DONE. Settings → Data has export (JSON/CSV),
backups, and Delete All Data.

PERMISSIONS
- Notifications: randomly timed survey prompts (the core mechanic); "nag"
  re-reminders are Time Sensitive notifications.
- Location (When in Use): stamps report location (speed, heading,
  altitude) and fetches weather (WeatherKit).
- Location (Always): asked contextually only when a prompt group uses a
  location trigger — arriving somewhere new (CLVisit), or entering/leaving
  a picked place or iBeacon (CLMonitor). Never at onboarding.
- Calendar (full access): read only, to fire a group when a matching event
  ends; event details never leave the device.
- Health (read): steps, heart rate, HRV, sleep, workouts, Activity rings —
  a per-report snapshot (syncs to private iCloud if sync is on).
- Health medications (separate per-object authorization, its own step):
  shows dose events the user already logged; no medical advice.
- Health (write): State of Mind only, for questions marked to log mood.
- Media & Apple Music: reads the current song, artist, and album; never
  any audio.
- Microphone: sampled to a single decibel number per report; no audio is
  recorded or stored.
- Photos: counts photos since the last report and stores their metadata
  (size, time, location); images are never read or uploaded.
- Motion & Fitness: stairs descended, to pair with Health's flights.
- Face ID: optional app lock.
- Focus status: whether a Focus was active; an optional Focus Filter can
  mute chosen prompt groups.
- Contacts (optional, default off; Settings → Sensors → "Suggest from
  Contacts"): matches names on device for chips; the link cache is
  device-local, photos live-fetched, never stored.
- Local Network: only if the opt-in webhook is configured; plain HTTP is
  limited to local hosts.

SPOTIFY (optional, opt-in)
Settings → Sensors → Spotify → Connect runs Spotify OAuth
(app-remote-control scope) via Spotify's official App Remote SDK. A
connected report can note the current track; the app keeps only a Keychain
token and reads now-playing. Nothing goes to us, an ad network, or a
broker. Disconnect deletes the token.

ICLOUD
Syncs via SwiftData's CloudKit mirroring to the user's own private CloudKit
database (Settings → Data → iCloud turns it off). Backups write to the Files
app and optionally the user's iCloud Drive; Delete All Data propagates
erasure. No synced data reaches the developer.

BACKGROUND MODES
remote-notification only (CloudKit silent pushes). Trigger groups relaunch
via HealthKit background delivery, EventKit, CLVisit, and CLMonitor — no
location background mode.

WEBHOOKS (opt-in, user-directed)
Off by default; sends the user's report JSON to the one endpoint they
entered; we run no server and receive nothing. HTTPS required for non-local
endpoints; optional HMAC signing + AES-256-GCM (OS CryptoKit;
ITSAppUsesNonExemptEncryption = NO).

COMMUNITY CATALOG (user-generated content)
Settings → Questions → Catalog browses shared question sets (public CloudKit
DB). Submissions include question text plus an opaque creator ID for moderation
(not name, email, or Apple ID); held for moderation, reportable/removable.

ORIGIN
Original, open-source (MIT) app inspired by Reporter (Nicholas Felton, 2014,
discontinued). No original Reporter code/assets/branding; imports Reporter's
JSON export. github.com/robbiet480/Dispatch
```

## Paste-ready reviewer notes (macOS)

*(The separate `io.robbie.Dispatch.mac` app record — far fewer permissions:
macOS has no HealthKit/microphone/motion/photo capture and no Spotify, and
the Mac app does not file reports.)*

```
Dispatch for Mac is the desktop companion to the iOS app: it displays the
user's self-tracking history and lets them manage their questions. It does
NOT file reports (no HealthKit/microphone/motion/photo/Spotify capture on
macOS) — reports are filed on iPhone/Apple Watch and sync here via the
user's private iCloud. No account or sign-in; no demo credentials.

QUICK LOOK: sign in to the same iCloud account as the iOS app; existing
reports and questions sync into the Dashboard, Insights, Questions, Groups,
and Catalog panes. With no iOS data yet, the panes are empty by design.

PERMISSIONS (macOS)
- Location (When in Use): requested ONLY when the user clicks "Use current
  location" while setting up a place-based prompt group — a one-shot
  CLLocationManager fix. Never at launch; if declined, they type an address
  instead. Sandboxed, with a purpose string in the build.
- No other sensor permissions: HealthKit, microphone, motion, photos,
  contacts, and Spotify are not used on macOS.

ICLOUD
Syncs via SwiftData's CloudKit mirroring to the user's own private CloudKit
database (Settings → iCloud turns it off). Export to a user-selected file
(JSON/CSV) uses the sandbox file picker. Nothing is accessible to the
developer or any third party.

COMMUNITY CATALOG (user-generated content)
The Catalog pane browses shared question sets from a public CloudKit
database; submissions contain only question text plus an opaque creator ID,
are moderated before appearing, and can be reported/removed.

ORIGIN
Original, open-source (MIT) app inspired by Reporter (Nicholas Felton, 2014,
discontinued). No original Reporter code, assets, or branding.
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
