# Dispatch Privacy Policy

*Effective 2026-07-12. Applies to the Dispatch apps for iOS, iPadOS,
watchOS, and macOS (bundle `io.robbie.Dispatch`), published by Robbie
Trencheny.*

Dispatch is a self-tracking app. Your data is the entire point of the
app, so this policy is blunt about exactly where it lives.

## The short version

- Everything you record stays **on your device** and, if you leave
  iCloud Sync on (it is on by default), in **your own private iCloud
  database**. There is no Dispatch server.
- **No analytics, no ads, no tracking.** The app makes no network
  connections except to Apple services (iCloud, Apple's weather
  service, push notifications), the shared community catalog (only if
  you explicitly submit a question set), a webhook endpoint you choose
  yourself (only if you configure one), and Spotify (only if you tap
  "Connect Spotify," to read what you're currently playing). Dispatch
  uses no analytics, advertising, tracking, or data-broker SDKs.
- **No Dispatch account.** Nothing to sign up for; we never see your
  email or name. Spotify sign-in is required only when connecting
  Spotify for now-playing detection.
- You can **export** everything (JSON/CSV), and **Delete All Data**
  (Settings → Data) erases every record, including the iCloud copy
  while sync is on.

## What Dispatch stores

When you file a report, Dispatch stores your answers plus the sensor
context you have granted access to:

- **Answers** — your responses to your questions, including free-text
  notes and the people/things/places you type.
- **Location** — coordinates, a reverse-geocoded place name, and —
  when available — your speed, heading, course, and altitude at the
  moment of the report (if you allow location access).
- **Health data** — snapshot readings from Apple Health at the moment
  of the report: steps, flights climbed, heart rate, HRV, resting
  heart rate, sleep, caffeine, workouts, Activity ring progress, and —
  if you grant the separate medications permission — medication dose
  events you logged in Apple Health (including the medication name). If you mark
  a question to log State of Mind, Dispatch also *writes* State of
  Mind entries to Apple Health.
- **Weather** — current conditions fetched from Apple's weather
  service (see below).
- **Now playing** — the title, artist, and album of what you're
  listening to when you file a report, read from Apple Music or, if
  you connect it, Spotify (see below). No audio is ever captured.
- **Ambient sound level** — a single decibel number. The microphone is
  sampled for loudness only; **no audio is ever recorded or stored**.
- **Photo activity** — a count of photos taken since your last report
  and basic metadata (dimensions, timestamps, location) of those
  photos. The photos themselves are never copied or uploaded.
- **Device context** — battery level, connectivity type, stairs
  descended (motion coprocessor), and whether a Focus was active (with
  the name you gave the Focus filter).

All of this is stored in a local database on your device.

## iCloud sync

If iCloud Sync is on (Settings → Data → iCloud; **default: on**),
Dispatch mirrors your reports, questions, prompt groups, and
vocabulary to the **private CloudKit database** of your own iCloud
account. That includes the Health readings attached to your reports —
we say this explicitly because it matters: **with sync on, snapshots
of your health data (including medication names, if you enabled that
sensor) are stored in your private iCloud database.** They are
encrypted in transit and at rest by Apple, visible to no one but your
signed-in iCloud account, and never touch any server of ours.

If you prefer your health data (or anything else) never to leave the
device, turn iCloud Sync off. The app is fully functional without it.

## Apple services

- **Weather** — to attach weather to a report, your current coordinates
  are sent to Apple's weather service (WeatherKit). Apple's handling is
  described in Apple's own privacy documentation; Dispatch sends
  nothing else.
- **Apple Health** — read and written only with your permission, on
  device, through HealthKit. Dispatch never transmits Health data to
  any third party. Health data appears in iCloud only via the sync
  described above.
- **Push notifications** — Dispatch uses silent CloudKit change
  notifications to keep devices in sync. No notification content is
  ever sent through any non-Apple service.

## The community question catalog

Browsing the catalog reads from a shared public CloudKit database. If
you **submit** a question set to the catalog, the questions you chose
to share (never your answers or reports) are uploaded to that public
database, where — after moderation — they are visible to all Dispatch
users. Submissions carry an opaque, per-app CloudKit identifier used
for moderation (rate limits, takedowns); it is not your name, email,
or Apple ID, and it is never displayed. Don't put personal information
in a submitted question set; submissions are public.

## Contacts (optional, off by default)

"People" in Dispatch are names — by default typed by you, with no
Contacts access at all. Two optional features use your contact book:

- **Contact suggestions** (Settings → Sensors → Suggest from Contacts;
  **default: off**) asks for Contacts permission and matches what you
  type against contact names to show name-and-photo suggestion chips.
- **Linking a person to a contact** (Settings → People) uses the
  system contact picker, which hands Dispatch only the single contact
  you pick and requires no Contacts permission.

What is stored: if you pick a contact, its display name becomes the
person's name in your data (and syncs like any other answer). The
*link* — the contact's device-local identifier plus normalized
email/phone match keys used to re-find it — is stored **only on that
device** and is never synced or exported. Contact photos are fetched
live from your contact book each time they are shown and are never
copied or persisted. No other contact data is read or stored, and
nothing from your contact book is ever transmitted anywhere.

## Webhooks (optional, off by default)

Settings → Data → Advanced → Webhook can POST a JSON copy of each
completed report to **one URL that you choose** — a home-automation
server, your own service, anything. Plainly:

- Entirely opt-in: nothing is sent unless you enter a URL and enable
  it. You can turn it off or change the destination at any time; the
  configuration is device-local and never syncs.
- What is sent is whatever your reports contain: your answers and any
  sensor context you have enabled (including Health readings, if those
  sensors are on). A "Send All Reports" action can send your history.
- **We operate no server and receive nothing.** The data goes directly
  from your device to the endpoint you configured; what that endpoint
  does with it is between you and its operator.
- Optional protections: with a secret set, requests carry an
  HMAC-SHA256 signature, and an Encrypt Payload option wraps the JSON
  in AES-256-GCM with a key derived from your secret. The secret is
  stored in the device Keychain (this-device-only).
- HTTPS is required for endpoints on the open internet; plain HTTP is
  allowed only for local-network destinations (localhost, `.local`
  hosts, private-range addresses). Choosing an endpoint — and securing
  the transport and storage behind it — is your responsibility.

## Spotify (optional, off by default)

If you connect Spotify (Settings → Sensors → Spotify → Connect),
Dispatch reads only your currently-playing track (title, artist,
album) to note it on a report, using Spotify's official App Remote
SDK. Authorization uses the `app-remote-control` scope; Dispatch
receives only an access token, stored in your device Keychain, never
your Spotify email or profile. Dispatch never sends your data to any
advertising network or data broker (Spotify's Developer Terms prohibit
this, and Dispatch doesn't). Spotify's own handling of your account
and listening data is covered by Spotify's privacy policy. Disconnect
any time in Settings, which deletes the token.

## What Dispatch does NOT do

- No analytics or telemetry of any kind. Not even crash reporting
  beyond Apple's own opt-in system diagnostics.
- No advertising, no tracking, no fingerprinting, no data sales.
- No analytics, advertising, tracking, or fingerprinting SDKs. The one
  third-party SDK in the app is Spotify's App Remote SDK, used solely
  to read your current track and only if you opt in by connecting
  Spotify (see "Spotify," above) — never for analytics, advertising,
  or tracking.
- No Dispatch accounts. Contacts are read only if you turn on the optional
  suggestions feature above (off by default), and even then nothing
  from your contact book leaves your device.

## Your data, your controls

- **Export** — Settings → Data exports everything as JSON or CSV.
- **Automatic backups** — daily rotating JSON backups (on by default,
  can be disabled). By default they are written both to the Files app
  on your device and to a visible "Dispatch" folder in **your iCloud
  Drive** — so, like sync, backup files (including any health readings
  in your reports) reach your own iCloud storage unless you set the
  backup destination to device-only in Settings → Data → Backups.
- **Delete** — Settings → Data → Delete All Data erases every record
  on the device and, while sync is on, propagates the erasure to your
  private iCloud database. Note: if you delete the *app* without
  running Delete All Data first, the iCloud copy survives (that is how
  iCloud works); reinstalling restores it, or you can remove Dispatch
  data in iOS Settings → your name → iCloud.
- Every sensor is individually toggleable, and every iOS permission
  can be denied or revoked at any time — reports simply omit that
  context.

## Children

Dispatch is not directed at children and has no age gate; it collects
nothing beyond what is described above in any case.

## Changes

Changes to this policy are published in this file's history in the
public repository (github.com/robbiet480/Dispatch) and take effect
when a build shipping them reaches the App Store.

## Contact

Questions: open an issue at github.com/robbiet480/Dispatch, or email
the address listed on the App Store page.

---

### Hosting note (not part of the policy)

This file is served via GitHub Pages from the repository: repo
**Settings → Pages → Source: Deploy from a branch → Branch: `main`,
folder `/docs`**. GitHub renders the markdown at
`https://robbiet480.github.io/Dispatch/privacy-policy`, which is the
URL to enter in App Store Connect (App Privacy → Privacy Policy URL).
One toggle, no build step; updates deploy on push to `main`.
