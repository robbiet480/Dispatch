# Dispatch — App Store listing kit

*Plan 23, Task 4. Copy is deliberately specific and superlative-free
(2.3.1 metadata rules); health integration is stated in the description
because 2.5.1 requires it. Character limits: name 30, subtitle 30,
keywords 100, promotional text 170.*

## Identity

| Field | Value | Notes |
|---|---|---|
| App name (ASC) | `Dispatch - Life Logger` | Already registered on ASC; plain "Dispatch" is taken. 22/30 chars |
| Home-screen name | `Dispatch` | `CFBundleDisplayName`, already set |
| Subtitle | `Randomly timed self-tracking` | 28/30 chars |
| Primary category | Lifestyle | Matches the genre Reporter shipped in |
| Secondary category | Health & Fitness | Honest signal given the Health integration |
| Price | Free | No IAP |
| Privacy Policy URL | `https://robbiet480.github.io/Dispatch/privacy-policy` | GitHub Pages, see docs/privacy-policy.md hosting note |
| Support URL | `https://github.com/robbiet480/Dispatch/issues` | Issues tracker doubles as support |
| Marketing URL | `https://github.com/robbiet480/Dispatch` | Repo README is the product page |

*The Identity table and the fenced blocks below are machine-read by
`scripts/asc-listing.swift` — keep the field names and code fences
intact when editing.*

## Description

```
Dispatch asks you a short set of questions a few times a day, at
moments you don't pick — how you're feeling, what you're doing, who
you're with — and quietly attaches the context of that moment. Answer
enough of them and a picture of your life emerges that no
end-of-day journal can match, because it was sampled while it
happened.

Dispatch is a universal app: file reports from your iPhone or Apple
Watch, and review, chart, and manage everything on iPad and Mac — all
synced through your own iCloud.

Each report can capture, with your permission:
• Where you are — with your speed, heading, and altitude — and the
  weather there
• Apple Health context: steps, flights, heart rate, HRV, sleep,
  workouts, caffeine, Activity rings — and, if you choose, the
  medications you logged in the Health app
• What's playing: the song, artist, and album from Apple Music, or
  from Spotify if you connect it (never any audio)
• Ambient loudness as a single decibel number (nothing is recorded)
• Photos taken since your last report (a count, never the photos)
• Battery, connectivity, and which Focus was on

Everything is a question you control: write your own, pick from a
community catalog, or import the questions you used in Reporter.
Number questions come with slider, stepper, dial, tap-counter, and
scale inputs. Answers can log State of Mind entries to Apple Health.

People you mention get stable identities: rename someone and your
history follows, merge duplicates, and — if you turn it on — get
name suggestions and photos from your contact book. Contact matching
stays on your device; nothing from Contacts is uploaded or synced.

Prompting is flexible: a global random schedule with quiet hours,
plus prompt groups that fire on their own schedule — every few hours,
at fixed times, when a workout ends, when a matching calendar event
ends, when you arrive at or leave a place you choose (by name,
address, or current location), when you come in range of an iBeacon,
or when you arrive somewhere new (power-efficient visit detection).
Set up only the triggers you want. Focus filters mute the groups you
choose while a Focus is on. Nag reminders can re-ping you until you
answer.

Your data works for you:
• Charts of every answer over time, plus an insights view that
  surfaces patterns ("reports mentioning gym average more steps")
• A weekly digest written on device with Apple Intelligence, with a
  built-in fallback summary
• Full-text and Spotlight search
• Home and lock screen widgets, a Control Center button that starts
  a report in one tap, and Siri Shortcuts and App Intents to file a
  report, log an answer, or check your streak hands-free
• Export everything as JSON or CSV, automatic daily backups (Files
  app and your own iCloud Drive), and one-button Delete All Data
• Optional webhooks: send each report's JSON to a URL you choose —
  your home-automation server, your own service — with signing and
  encryption options

Privacy, plainly: there is no server, no account, and no analytics or
tracking. The only third-party code is Spotify's official SDK — used
just to read your current track, and only if you connect Spotify
yourself. Data stays on your device and — if you leave iCloud Sync and
iCloud Drive backups on — in your own private iCloud storage, which
includes the Health readings attached to your reports. The app makes
documented requests to Apple's weather service (WeatherKit) to fetch
conditions for your location, and — if you explicitly submit a question
set — uploads it to a shared community catalog. Optional webhooks send
reports to an endpoint you configure. With iCloud Sync and backups off,
and absent those opt-in actions, nothing else leaves the device. Full
policy inside the app and at the privacy policy link.

Dispatch is an independent, open-source reimplementation inspired by
Reporter, the discontinued self-tracking app — original code and
design, and it imports your old Reporter export directly.
```

## Description (macOS)

*The Mac app is a SEPARATE App Store record (`io.robbie.Dispatch.mac`), so
it needs its own description — this block. Honest about the Mac being a
companion: it does NOT file reports or capture sensors (no HealthKit/mic/
motion/photos/Spotify on the Mac build) — reports are filed on iPhone/Watch
and sync here — and its only sensor is a one-shot location fix for setting
up place triggers. `asc-listing.swift` targets the iOS record only; pushing
this to the Mac record is a separate lane (or set it by hand in ASC).*

```
Dispatch on the Mac is the companion to the iPhone and iPad app: your
self-tracking history, on a screen with room to see it. You file reports
on your iPhone or Apple Watch — a short set of your own questions, a few
times a day, at moments you don't pick — and everything syncs here through
your own private iCloud.

On the Mac, that history opens up:
• A dashboard of every report, with charts of each answer over time
• An insights view that surfaces patterns across your history
• Full-text search over everything you've logged
• The people you mention, with stable identities you can rename and
  merge — and your whole history follows

Your questions live here too. Write and edit them, pick from a community
catalog of shared question sets (or contribute your own), and import the
questions you used in Reporter. Organize the prompt groups that decide when
your iPhone asks — including groups that fire when you arrive at a place,
which you can set up right on the Mac.

When you want your data elsewhere, export everything as JSON or CSV.

The rich context on each report — Apple Health, weather, what's playing,
ambient loudness, which Focus was on — is captured by Dispatch on iPhone
and Apple Watch and appears here through sync. The Mac itself only ever
reads your location, and only for the one-time fix when you set up a place
trigger.

Privacy, plainly: there is no server, no account, and no analytics or
tracking. Your reports stay on your devices and in your own private iCloud
storage — the developer can't see them. Turn iCloud Sync off and nothing
leaves your Mac.

Dispatch is an independent, open-source reimplementation inspired by
Reporter, the discontinued self-tracking app — original code and design,
and it imports your old Reporter export directly.
```

## Keywords (100 chars max)

```
self tracking,quantified self,life log,journal,diary,mood,check in,survey,reporter,felton,data,csv
```
98/100 chars. Rationale: exact-match phrases people used to find
Reporter and its successors; "felton" catches original-app searches;
no competitor app names beyond the discontinued app Dispatch openly
credits.

## Promotional text (editable without review, 170 max)

```
Random check-ins with real context: location, weather, Health,
Focus. On device and in your own iCloud — no server, no account, no
analytics.
```

## What's New — 1.0 draft

```
First App Store release. Dispatch prompts you a few times a day and
attaches the moment's context to each answer.

• Runs on iPhone, iPad, Apple Watch, and Mac, synced through your own
  iCloud
• Random survey prompts with quiet hours, plus prompt groups that fire
  every few hours, at set times, when a workout ends, when a calendar
  event ends, when you arrive at or leave a place, or near an iBeacon
• Captures location (with speed, heading, altitude) and weather, Apple
  Health (including medications and State of Mind), what's playing
  (Apple Music, or Spotify if you connect it), ambient sound level,
  photo counts, battery, connectivity, and Focus
• Charts, an insights view, and a weekly on-device digest
• Home and lock screen widgets, a Control Center button, and Siri
  Shortcuts / App Intents to file a report or log an answer hands-free
• People management with optional Contacts suggestions
• JSON/CSV export, automatic backups to Files and iCloud Drive,
  optional signed webhooks, and one-tap Reporter import
```

## Age rating questionnaire

Every content question — violence, sexual content, profanity, horror,
gambling, contests, drugs — answers **None**. Specific answers worth
noting:

| Question | Answer | Why |
|---|---|---|
| Medical/Treatment Information | **None** | Dispatch displays the user's own Health data and logs medication *events they already recorded*; it gives no medical information or advice |
| Alcohol, Tobacco, or Drug Use or References | None | Medication logging is the user's own data, not drug references/content |
| Unrestricted Web Access | No | No web views |
| Gambling and Contests | No | — |
| Made for Kids | No | — |

Expected rating: **4+**.

## Additional ASC settings

- **Content rights:** does not contain third-party content.
- **Export compliance:** uses only exempt (OS-provided) encryption —
  `ITSAppUsesNonExemptEncryption` NO already in the Info.plist, so ASC
  won't re-ask per build.
- **App uses IDFA:** No.

---

## Wrap: launch-gate status (plan 23 completion note)

Task 1's risk register (see [review-readiness.md](review-readiness.md)):

1. **5.1.3(ii) health-in-iCloud — OWNER-ACCEPTED, not a code gate.**
   Ship as-is; reviewer notes carry the snapshot/private-DB framing;
   escalation ladder ends at the local-only health sidecar (2–4 d) if
   Apple rejects twice. Labels + policy + this listing all *disclose*
   the sync rather than deny it — consistency check in
   [privacy-labels.md](privacy-labels.md).
2. **Delete All Data — RESOLVED** (shipped, commit `2c196fb`).
3. **Three-way labels/policy/code consistency — DONE** in
   privacy-labels.md against this branch.

Remaining pre-submission checklist (not code):
- Verify `aps-environment=production` in the release archive (2.3.1
  watch item).
- Optional 1 h: rewrite the four onboarding headlines that match the
  original Reporter's (4.1 belt-and-braces; low risk as-is).
- Run `./scripts/screenshots.sh` on the release build and upload the
  6.9" set.
