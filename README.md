# Dispatch

Dispatch is an iOS app for self-tracking through randomly timed surveys.
A few times a day, at moments you don't control, Dispatch asks you a short
set of questions — how you're feeling, what you're doing, who you're
with — and quietly attaches the sensor context of that moment: location,
steps and heart rate from Health, ambient noise level, nearby photo
activity, and whether a Focus was active. Answer enough of them over
weeks and months and a genuinely useful picture of your life emerges,
one you can search, chart, and export whenever you want.

Dispatch is an original, from-scratch implementation inspired by
*Reporter*, the pioneering self-tracking app built by Nicholas Felton and
Drew Breunig and discontinued years ago. No Reporter code, assets, or
branding are used; Dispatch has its own design and codebase, built to
let people keep using the format Reporter popularized — and it imports
Reporter's documented export format directly, so nobody's history is
stranded.

## Screenshots

Screenshots are generated automatically from seeded demo data by
[`scripts/screenshots.sh`](scripts/screenshots.sh) (see
[Automated screenshots](#automated-screenshots)); the output lands in
`docs/app-store/screenshots/` (gitignored — run the script to produce a
fresh set for the current build).

## Features

### Capture

- **Randomly timed surveys** — configurable question sets fire at
  unpredictable times throughout the day, avoiding the bias of
  fixed-schedule check-ins. Set how many prompts you want per day, an
  awake/asleep window, and how they distribute.
- **Rich question types** — yes/no, multiple choice, tokens (things,
  people, places with autocomplete from your own vocabulary), free
  text, location, and numbers — with five number input styles: slider,
  stepper, dial, tap counter, and labeled scale.
- **Sensor context capture** — each report can be enriched with
  location, weather (WeatherKit), steps/flights/heart rate/HRV/sleep/
  workouts/caffeine/activity rings/medications from Apple Health,
  stairs descended (motion coprocessor), ambient sound level (a decibel
  number only — nothing is recorded), photo count since your last
  report, battery, connectivity, and the active Focus. Every sensor is
  individually toggleable; deny a permission and that context is simply
  omitted.
- **State of Mind logging** — questions can optionally log an Apple
  Health State of Mind entry from your answer.
- **Nag reminders** — optional persistent re-reminders until you act on
  a prompt, with per-device snooze.

### Prompt groups

Question sets with their own schedules, independent of the main random
prompts. Triggers: every N hours, N times per day, at fixed daily
times, **when a workout ends** (HealthKit background delivery), and
**when you arrive somewhere** (power-efficient CLVisit monitoring —
this is the one feature that asks for Always location, and only when
you schedule an arrival group).

### Focus filters

Attach Dispatch to any Focus mode: reports record the Focus's name, and
you choose which prompt groups may fire while it's on (optionally
pausing the main schedule too). See [Focus filters](#focus-filters-1).

### Review

- **Visualizations** — the home screen is a chart of your answers over
  time (proportion bands, numeric trends), filterable per question.
- **Insights** — on-device association surfacing across your reports
  ("Reports where you mention gym average 2,400 more steps"), computed
  on demand, careful to say "tends to" rather than claim causation, and
  honest about sample size.
- **Weekly digest** — an on-device (Apple Intelligence) narrative recap
  of your week with a deterministic summary fallback, and an optional
  Sunday-evening reminder.
- **Search** — full-text search across reports, plus Spotlight indexing.
- **Widgets & Control Center** — home/lock screen widgets (time since
  last report, today's count, streak), an interactive quick-answer
  widget that files a response without opening the app, and a Control
  Center control that starts a new report with one tap.

### Questions

- Author question sets in the app, or browse the **community question
  catalog** — a moderated, CloudKit-public-database library of question
  sets you can add with one tap (and submit to). Moderation runs
  through the `dispatch-mod` CLI in this repo.

### Your data

- **On-device first** — there is no backend server and no analytics.
  Data lives in a local SwiftData store.
- **iCloud sync (optional, default on)** — reports, questions, prompt
  groups, and vocabulary mirror to your private CloudKit database.
  Note that this includes the Health readings attached to reports; the
  privacy policy ([docs/privacy-policy.md](docs/privacy-policy.md))
  spells this out. See [iCloud sync](#icloud-sync).
- **Automatic backups** — daily rotating JSON backups, on by default,
  written to the Files app and (by default) a visible "Dispatch"
  folder in your iCloud Drive; destination configurable. See
  [Backups](#backups).
- **Import & export** — import an original Reporter export or a
  Dispatch export; export everything back out as JSON or CSV any time.
- **Webhooks** — optionally POST each completed report's JSON to a URL
  you choose (Settings → Data → Advanced), with HMAC signing and
  AES-256-GCM payload encryption available; entirely opt-in,
  device-local config, no server of ours involved.
- **Delete All Data** — Settings → Data wipes every record, and while
  sync is on the deletions propagate to the iCloud copy too.
- **Face ID app lock** — optional biometric lock with an app-switcher
  privacy cover.

### People

People you mention get stable identities: rename a person and history
follows, merge duplicates, and manage everyone in Settings → People.
Optional Contacts integration (off by default) suggests names from
your contact book as you type and shows contact photos — matching and
linking stay on-device, and nothing from your contact book is synced
or transmitted. Landing in a parallel branch (plan 22) alongside this
one.

## Architecture

- **`Sources/DispatchKit/`** — a local Swift package holding all
  testable logic: models (SwiftData, CloudKit-compatible), capture
  coordination, prompt planning, import/export (Reporter v1 + Dispatch
  v2 schemas), search, visualization/insights/digest engines, backup
  rotation, catalog types, and widget snapshot logic. No UIKit/SwiftUI
  app dependencies, so `swift test` runs the whole suite from the CLI.
- **`App/Sources/`** — the SwiftUI app (module `DispatchApp`): views,
  providers (the real sensor integrations), notification scheduling
  glue, sync policy, and intents.
- **`Widgets/Sources/`** — the widget extension (`DispatchWidgets`),
  which reads the shared App Group store directly (read-only).
- **`Mac/Sources/`** — the native macOS app (`DispatchMac`): a
  review-and-analyze shell over the same kit (reports split view with
  search, the visualizations dashboard, insights, imports, and the
  journaling-ecosystem exports — Day One JSON, Markdown/Obsidian) PLUS
  the setup surfaces the big-keyboard device is for — question
  management (create/edit/reorder/enable/disable/delete + CSV/JSON
  definition import & export), prompt-group management, and
  community-catalog access (browse, add, submit, flag). Reachable from
  the detail-pane switcher and the **Manage** menu (⌘1–⌘5). It syncs
  through the same CloudKit container (its store lives in its own
  Application Support — CloudKit is the only data channel). Capture
  still stays on iPhone/Apple Watch by design: no sensors, notifications,
  widgets, or app lock on the Mac, and sensor-driven prompt schedules
  (workout end, arrival, calendar-event end) are configurable on the Mac
  but fire on your iPhone. A group or question edited on the Mac syncs
  to the phone, whose `RemoteChangeObserver` replans notifications so
  the edit takes effect without waiting for the next app open.
- **`Sources/dispatch-mod/`** — a macOS-only executable target for
  moderating the community catalog via CloudKit Web Services. Never
  compiled into the iOS app.
- **XcodeGen** — `Dispatch.xcodeproj` is generated from
  [`project.yml`](project.yml) and gitignored; run `xcodegen generate`
  after cloning or changing project settings.
- **Tests** — 350+ Swift Testing tests in `Tests/DispatchKitTests`
  (run with `swift test`), plus XCUITest suites in `AppUITests/`
  covering navigation, the survey flow, digest, insights, catalog,
  app lock, delete-all, Focus filters, and accessibility. App Store
  screenshots are generated by a separate, opt-in UI test class (see
  below) that skips itself unless `SCREENSHOT_MODE=1` is in the test
  environment, so default runs are unaffected.

## Building from source

### Requirements

- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 26 SDK / simulator (or a device running iOS 26+)

```sh
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Or open `Dispatch.xcodeproj` in Xcode after `xcodegen generate`. Kit
tests need no simulator: `swift test`.

The macOS app builds from the same project:

```sh
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac \
  -destination 'platform=macOS' build
```

Its entitlements (CloudKit, `com.apple.developer.aps-environment`)
require a "Mac App Development" provisioning profile for the
`io.robbie.Dispatch.mac` App ID — register it on the portal with the
iCloud container + Push capabilities (see the fork checklist), or let
Xcode's automatic signing create it. To verify only that the code
compiles, build with `CODE_SIGNING_ALLOWED=NO`.

### Fork checklist (entitlements & portal prerequisites)

Dispatch uses capabilities that require a **paid** Apple Developer
Program membership and per-team portal setup. `project.yml` is
configured with `DEVELOPMENT_TEAM: UTQFCBPQRF`; change it to your own,
then:

1. **WeatherKit** — enable the WeatherKit capability for your app ID in
   the developer portal (weather is fetched via the entitlement; no API
   key in the app).
2. **iCloud container** — create your own CloudKit container, then
   update the identifier in `App/Sources/Sync/SyncPolicy.swift`
   (`containerIdentifier`), `App/Dispatch.entitlements`, and the
   catalog code if you want your own community catalog. After the first
   run against the Development environment, open CloudKit Console and
   **deploy the schema to Production** — TestFlight/App Store builds
   sync against Production, and skipping the deploy makes sync a silent
   no-op there even though it works fine from Xcode.
3. **Push notifications** — the `aps-environment` entitlement powers
   CloudKit's silent change pushes (`UIBackgroundModes:
   remote-notification`); enable Push Notifications on your app ID.
4. **App Group** — the store lives in `group.io.robbie.Dispatch` so the
   widget can read it; register your own group and update
   `StoreLocation.appGroupID` plus both entitlements files.
5. **HealthKit** — enable HealthKit (with background delivery) on the
   app ID.

If you build with a free-tier team, Xcode drops the entitlements it
can't provision; Dispatch degrades gracefully in every such case
(weather, Health, sync, and Focus context are omitted) rather than
crash. Focus-state capture needs no entitlement — only the usage
description (already set) and the user's authorization.

### Release pipeline

`./scripts/upload-testflight.sh [notes.md]` runs the whole headless
pipeline: xcodegen → archive → manually-signed App Store export →
upload, with optional TestFlight "What to Test" notes set via the App
Store Connect API after processing. It expects an ASC API key and
local signing assets described in the script; both targets'
`CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` must stay matched or ASC
rejects the archive.

### Automated screenshots

```sh
./scripts/screenshots.sh
```

Boots the App-Store-required simulators, runs the `ScreenshotTests`
XCUITest class over `--demo-data` seeded fixtures (deterministic,
visually rich demo reports), extracts the full-screen PNG attachments
from the `.xcresult`, and writes them to `docs/app-store/screenshots/`
as `<device>-<nn>-<name>.png`. Idempotent; one command. The widget
gallery cannot be captured this way (XCUITest cannot drive the
widget-add sheet) — those shots, if wanted, are manual.

## iCloud sync

Dispatch mirrors its SwiftData store to the private CloudKit database
`iCloud.io.robbie.Dispatch` using SwiftData's built-in CloudKit support —
no custom sync engine, no server of ours.

**What syncs:** reports (with all responses and sensor context,
including attached Health readings), questions, prompt groups, and the
token/people vocabulary.

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

**Diagnostics:** Settings → iCloud → Diagnostics is a read-only evidence
screen for troubleshooting sync (so TestFlight reports carry facts, not
anecdotes). It shows the iCloud account status, a timeline of observed
sync events (store-change bursts, dedupe passes, pipeline errors, and —
where the platform surfaces them — CloudKit import/export results),
lifetime dedupe merge counts (the duplicate rows cross-device sync can
create are collapsed automatically), and a per-device breakdown of how
many reports each device filed. It is deliberately honest: it reports
only observed facts, with no spinner or fake "syncing" progress, and the
STATUS caption is named **"Last store change observed"** — a store change
being observed is NOT the same as a confirmed successful sync (a
CloudKit export result, when the platform exposes one, is the stronger
signal). When sync is on and iCloud is reachable but nothing has been
observed since launch, it says exactly that rather than implying trouble.

An **Export Diagnostics** button shares a plain-text dump for bug
reports. It is privacy-safe by construction (pinned by a test): it
contains the app/OS/device version, the sync toggle and account status,
the event timeline, dedupe counts, and per-device report counts — and
NEVER your reports, answers, question prompts, vocabulary, or health
data. Nothing from inside a report beyond its existence count per device
is included, and errors are sanitized (domain/code/description only).

**Privacy:** the private CloudKit database only. Nothing is shared,
public, or visible to anyone but the signed-in iCloud account. The full
policy is in [docs/privacy-policy.md](docs/privacy-policy.md).

**Sync is not a backup:** sync faithfully propagates every change —
including deletions and bad imports — to all your devices; only
[Backups](#backups) (or a manual export) let you rewind to an earlier
state.

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
- Backups are written to the Files app under **On My iPhone →
  Dispatch → Backups** (and Finder when the device is connected) and,
  by default, also to a visible **Dispatch folder in iCloud Drive**
  (plan 25) — the destination picker in Settings → Data → Backups
  offers device-only, iCloud-only, or both, and iCloud writes fall
  back to local when iCloud is unavailable. Local copies survive app
  deletion only if you copy them out; the iCloud Drive copies survive
  it by nature.
- To restore, use Settings → Data → Import… and pick a backup file.
- Everything is foreground-scheduled: no background tasks, no servers
  of ours. iCloud sync is not a backup (it propagates deletions);
  these files are your rewind point.

## People

People you name in reports are stable identities, not just text
(Settings → People):

- **Rename heals history.** Renaming a person moves the old name into
  their alternate names: past reports keep the text you actually
  typed, but visualizations, insights, filters, and suggestions all
  count both names as the same person and display the current name.
- **Merge duplicates.** Multi-select two or more people to merge them
  — names union, counts sum. Duplicate entries arriving via iCloud
  sync merge the same way automatically.
- **Contacts are optional and device-local.** "Suggest from Contacts"
  (Settings → Sensors, off by default) blends contact names and photos
  into the people typeahead. Contact links — including the ones made
  by "Link to Contact" on a person — are a per-device cache: contact
  identifiers and photos are never stored in your data and never sync,
  because Apple's contact identifiers only identify a contact on one
  device. Photos are fetched live from the linked contact for display
  only.
- **Known limitation:** two different people who share an identical
  full display name collapse into one person — answers are stored as
  name text, so the fix is distinct names (e.g. add a last initial).
- Deleting a person removes only the registry entry; reports are
  untouched, and a plain entry may reappear if the name still occurs
  in reports.

## Importing an original Reporter export

Reporter's export format (`{"questions": [...], "snapshots": [...]}`) is
supported directly. From Settings → Data → Import…, choose your
exported `.json` file. Dispatch detects whether the file is a Reporter
(v1) export or a Dispatch (v2, `schemaVersion: 2`) export automatically
and imports accordingly, then rebuilds its search index. You'll see a
summary of how many reports, questions, and responses were imported
(and how many records were skipped because they were malformed).

## Contributing

Issues and PRs welcome. Ground rules:

- Testable logic goes in `DispatchKit` with Swift Testing coverage
  (`swift test` must stay green); UI behavior gets an XCUITest where
  practical (`--ui-testing`/`--mock-sensors` launch args give tests an
  in-memory store and mocked sensors — keep new system-API code gated
  the same way).
- The Xcode project is generated: edit `project.yml`, never the
  `.xcodeproj`.
- Model changes must respect the CloudKit rules (optional/defaulted
  attributes, optional relationships, no `#Unique`) and the v2 export
  schema's compatibility notes in `Sources/DispatchKit/V2`.

## App Store documents

The listing kit lives in [`docs/app-store/`](docs/app-store/): review
readiness analysis, listing copy, privacy nutrition labels, and
reviewer notes. The privacy policy is
[docs/privacy-policy.md](docs/privacy-policy.md).
`scripts/asc-listing.swift` pushes the kit to App Store Connect
(dry-run by default, never submits for review — see
[docs/app-store/asc-automation.md](docs/app-store/asc-automation.md)).

## License

MIT — see [LICENSE](LICENSE).
