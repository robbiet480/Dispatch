# Dispatch

Dispatch is an iOS app for self-tracking through randomly timed surveys.
A few times a day, at moments you don't control, Dispatch asks you a short
set of questions — how you're feeling, what you're doing, who you're
with — and quietly attaches the sensor context of that moment: location,
steps and heart rate from Health, ambient noise level, nearby photo
activity, and whether a Focus was active. Answer enough of them over
weeks and months and a genuinely useful picture of your life emerges,
one you can search, chart, and export whenever you want.

This project draws its inspiration from *Reporter*, the pioneering
self-tracking app built by Nicholas Felton and Drew Breunig and later
discontinued — Dispatch is a from-scratch reimplementation of that idea
for a modern iOS, with its own design and codebase, built to let people
keep using the format Reporter popularized and to import their existing
Reporter exports.

## Features

- **Randomly timed surveys** — configurable question sets fire at
  unpredictable times throughout the day, avoiding the bias of
  fixed-schedule check-ins.
- **Sensor context capture** — each report can be enriched with
  location, weather, steps/heart rate/HRV/sleep/workouts from Apple
  Health, stairs climbed and descended, ambient sound level, recent
  photo count, and Focus state, depending on what you grant access to.
- **Rich question types** — scales, choices, free text, and more, with
  per-question Health "State of Mind" logging when you opt in. Author
  question sets in the app.
- **Search** — full-text and Spotlight-indexed search across your
  reports.
- **Visualizations** — charts and summaries of your answers over time.
- **Home & lock screen widgets** — time since your last report, today's
  count, and your streak, plus a Control Center control that starts a
  new report with one tap.
- **Weekly digest** — an on-device (Apple Intelligence) narrative recap
  of your week, with a deterministic summary fallback and an optional
  Sunday-evening reminder.
- **Focus filters** — attach Dispatch to any Focus mode to record the
  Focus's name in reports and limit which prompt groups fire while it's
  on. See [Focus filters](#focus-filters).
- **Face ID app lock** — optional biometric lock on launch.
- **Import & export** — bring in an original Reporter export or a
  Dispatch export, and export your data back out as JSON or CSV at any
  time. Everything lives on-device; there is no backend server.
- **Automatic backups** — daily rotating JSON backups written to the
  Files app, on by default. See [Backups](#backups).
- **iCloud sync** — reports, questions, prompt groups, and vocabulary
  sync across your devices through your private iCloud database. See
  [iCloud sync](#icloud-sync).

## Requirements

- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 26 SDK / simulator (or a device running iOS 26+)

## Building

```sh
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Or just open `Dispatch.xcodeproj` in Xcode after running `xcodegen generate`.

### Entitlements note

Dispatch ships with WeatherKit and HealthKit entitlements. These require
a paid Apple Developer Program membership tied to a real team ID —
`project.yml` is configured with `DEVELOPMENT_TEAM: UTQFCBPQRF`; change
it to your own.

Focus-state capture needs no entitlement — only the Focus Status usage
description (already set) and the user's authorization, which iOS prompts
for on first capture. If authorization is declined, Focus context is
simply omitted from reports.

If you build with a free-tier team, Xcode will drop entitlements it
can't provision; Dispatch degrades gracefully in every such case
(weather, Health, and Focus context are omitted from reports) rather
than crash.

## iCloud sync

Dispatch mirrors its SwiftData store to the private CloudKit database
`iCloud.io.robbie.Dispatch` using SwiftData's built-in CloudKit support —
no custom sync engine, no server of ours.

**What syncs:** reports (with all responses and sensor context),
questions, prompt groups, and the token/people vocabulary.

**What stays device-local** (deliberately, in UserDefaults): nag state
(`lastActedAt` — each device nags for its own delivered prompts),
notification preferences (alerts per day, distribution, scheduled times,
nag settings), the awake/asleep state, theme, units, Face ID app lock,
onboarding progress, sensor toggles, visualization filters, and the
iCloud Sync toggle itself. Notification schedules are re-planned per
device from the synced questions and groups.

**Toggle semantics:** Settings → Data → iCloud has an "iCloud Sync"
toggle (default ON). It takes effect after reopening Dispatch — the
store is chosen once at launch; swapping it under live views mid-flight
is deliberately avoided. Turning sync off keeps all data on-device;
export remains the manual escape hatch. If CloudKit isn't available at
launch (no iCloud account, missing container), Dispatch logs the reason
(OSLog category `sync`) and falls back to the local store — the app
never fails to launch over sync.

**Privacy:** the private CloudKit database only. Nothing is shared,
public, or visible to anyone but the signed-in iCloud account.

**Sync is not a backup:** sync faithfully propagates every change —
including deletions and bad imports — to all your devices; only
[Backups](#backups) (or a manual export) let you rewind to an earlier
state.

**If you fork this:** create your own iCloud container in the developer
portal, update the identifier in `SyncPolicy.containerIdentifier` and
`App/Dispatch.entitlements`, and — the classic trap — after the first
run against the Development environment, open CloudKit Console and
**deploy the schema to Production**. TestFlight/App Store builds sync
against Production; skipping the deploy makes sync a silent no-op there
even though it works fine from Xcode.

## Focus filters

Dispatch ships a Focus Filter, so each Focus mode can have its own
prompting behavior:

- **Named Focus capture** — reports record the name you give the filter
  (e.g. "Work") instead of just "Focus: On". Apple exposes no API for
  the actual Focus mode name, so you name it once during setup.
- **Per-Focus prompt groups** — pick which prompt groups may fire while
  that Focus is on; everything else is muted until the Focus turns off.
- **Pause ungrouped prompts** — optionally pause the main (ungrouped)
  notification schedule too, so *only* the selected groups fire.

Setup (per Focus mode, in the system Settings app — Apple provides no
in-app enrollment): **Settings → Focus → choose a mode → Focus Filters →
Add Filter → Dispatch**, then name the filter and select prompt groups.
Leaving the prompt-groups row untouched means "no restriction" — a
name-only filter records the Focus name without muting anything; to
mute all group prompts, open the row and explicitly clear the
selection. Snoozed prompts always fire, even for muted groups — a
snooze is an explicit "remind me" that outranks the filter.
When the Focus turns off or switches, the full schedule resumes
automatically. Persistent reminders remain Time Sensitive, so they can
still break through the Focus itself for prompts that do fire.

## Backups

Dispatch automatically keeps rotating backups of your data (on by
default; Settings → Data → Backups):

- A full JSON export (the same v2 format as manual export) is written
  when you open the app or file a report and the newest backup is more
  than 20 hours old — roughly one per day of use. The newest 14 are
  kept.
- Backups live in the Files app under **On My iPhone → Dispatch →
  Backups** (and in Finder when the device is connected), so they
  survive app deletion only if you copy them out — grab one any time,
  or use "Back Up Now" first.
- To restore, use Settings → Data → Import… and pick a backup file.
- Everything is on-device and foreground-scheduled: no background
  tasks, no servers. iCloud sync is not a backup (it propagates
  deletions); these files are your rewind point.

## Importing an original Reporter export

Reporter's export format (`{"questions": [...], "snapshots": [...]}`) is
supported directly. From Settings → Data → Import…, choose your
exported `.json` file. Dispatch detects whether the file is a Reporter
(v1) export or a Dispatch (v2, `schemaVersion: 2`) export automatically
and imports accordingly, then rebuilds its search index. You'll see a
summary of how many reports, questions, and responses were imported
(and how many records were skipped because they were malformed).

## License

MIT — see [LICENSE](LICENSE).

## Screenshots

Coming soon.

- [ ] Add screenshots captured from a real device once available.
