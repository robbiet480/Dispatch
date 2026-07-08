# Dispatch — an open-source Reporter clone (design spec)

**Date:** 2026-07-07
**Status:** Approved by Robbie (pending spec review)

## 1. Product

Dispatch is a native SwiftUI iPhone app (iOS 17+) that replicates the
self-tracking loop of Nicholas Felton's discontinued Reporter app:

1. Randomly timed local notifications prompt you to file a report.
2. Starting a report auto-captures sensor context (location, weather,
   altitude, photo count, ambient audio level, steps, stairs, battery).
3. You answer a personalized, ordered list of questions (7 types).
4. Reports are stored locally, synced via iCloud, visualized in-app, and
   exportable as JSON/CSV.

Open source on GitHub under MIT, with an original name ("Dispatch") and an
original icon. The interaction model and flat color-themed aesthetic follow
the original; no assets, artwork, icon, or the "Reporter" name are copied.

Reference material (not committed): 21 UI screenshots and
`reporter-export.json` (94 snapshots, 38 questions) from Robbie's original
install. The export defines the interchange schema.

## 2. Data model

SwiftData models, CloudKit-mirrored (all properties optional or defaulted, no
unique constraints; dedupe by `uniqueIdentifier` in code). The JSON export
schema is the source of truth so import/export round-trips.

### Question

| Field | Notes |
|---|---|
| `uniqueIdentifier` | string (UUID or `default-question-N`) |
| `prompt` | display text |
| `questionType` | int enum, below |
| `placeholderString` | optional (e.g. "No one", "50.00") |
| `choices` | `[String]` — **not present in export** (`answers: null`); local-only field, seeded per below |
| `sortOrder` | local-only; export order otherwise |
| `isEnabled` | local-only; screenshots show ON/OFF toggles |
| `selectedVisualizations` | pass-through for round-trip fidelity |

Question types (verified against export):

| Int | Type | Answer UI |
|---|---|---|
| 0 | Tokens | free-text chips with autocomplete from token vocabulary |
| 1 | Multi-Choice | option list, one or many selectable (checkmark) |
| 2 | Yes/No | two-row list |
| 3 | Location | current place name + Foursquare-style venue text field |
| 4 | People | like tokens, backed by people vocabulary + contacts autocomplete |
| 5 | Number | numeric keypad |
| 6 | Note | free multiline text |

Multi-choice caveat: the export does not carry option lists, so imported
multi-choice questions get their options seeded empty and editable in
Question Settings. Newly created questions store options locally and export
them (schema superset; the original app ignores unknown keys).

### Report (a.k.a. snapshot)

Fields mirror the export exactly: `uniqueIdentifier`, `date`,
`sectionIdentifier` (`{background}-{yyyy}-{M}-{d}`), `battery` (0–1),
`steps` (int), `altitude` (m), `background` (0/1), `draft` (0/1),
`reportImpetus` (int: how the report was started), `connection` (int),
`audio` (`avg`/`peak` dB floats), `location` (lat/lon, speed, course,
accuracy + nested `placemark` with locality/thoroughfare/etc.),
`weather` (full observation blob: tempF/tempC, feelslike, wind, pressure,
humidity, visibility, uv, precip, stationID, `weather` condition string),
`photoSet` (array of photo metadata: assetUrl, dimensions, dateTime,
lat/lon/altitude, depth).

WeatherKit populates a subset of the weather blob (temp, feels-like, wind,
pressure, humidity, visibility, uv, condition); remaining keys are omitted.

### Response

One per answered question per report: `uniqueIdentifier`, `questionPrompt`
(string join key — matches original behavior), plus exactly one payload:

| Payload | For type | Shape |
|---|---|---|
| `tokens` | 0, 4 | `[{uniqueIdentifier, text}]` |
| `answeredOptions` | 1, 2 | `[String]` |
| `locationResponse` | 3 | `{text, foursquareVenueId?, location{...}, uniqueIdentifier}` |
| `numericResponse` | 5 | string-encoded number |
| `textResponses` | 6 | `[{uniqueIdentifier, text}]` |
| *(none)* | any | question shown but skipped |

### Vocabularies

`Token` and `Person` entities (`text`, usage count derived by query) power
autocomplete and the Custom Tokens screen ("41 TOKENS — Used N times in M
questions").

## 3. Screens

- **Onboarding** — 4-page carousel (teal/pink/chartreuse/gray): value prop,
  data privacy, sensor permission priming, customization. Geometric
  triangle-grid illustrations drawn in SwiftUI/Canvas (original-but-similar).
  Ends with DONE.
- **Home** — full-bleed theme color; centered hexagon button ("Edit your
  questions" when empty → question settings; otherwise decorative status);
  bottom bar: REPORT (new report) + AWAKE/ASLEEP toggle; top bar: reports
  list (hamburger) + settings (gear). When reports exist: swipeable
  per-question visualization pages with a "Filter Visualizations…" bar and
  page dots.
- **Report flow** — full-screen cover. Page 1: sensor capture checklist
  ticking through "GETTING WEATHER CONDITIONS…" → results ("207 FEET",
  "EXTREMELY QUIET 24.40 DB", "27,851 STEPS TAKEN", "7 STAIRCASES UP 2
  DOWN", "UNABLE TO DETECT WEATHER" on failure), with the first question
  visible below. Subsequent pages: one question each. Progress bar top,
  CANCEL / page-dots / NEXT (→ DONE) bottom. Answers save on DONE; CANCEL
  discards (draft flag reserved for future).
- **Reports list** — swipeable stats header (page 1: N REPORTS / N DAYS /
  AVG PER DAY; page 2: N TOKENS / N LOCATIONS / N PEOPLE), then reports
  grouped by day ("THURSDAY — DEC 13, 2018"), each row time + place. Tap →
  report detail (sensor summary + responses, editable).
- **Settings** — sections: SCHEDULE (Notifications → next alert time),
  SURVEY (Questions, Sensors), DATA (Export, iCloud sync toggle with last-
  synced caption), INTERFACE (5 theme swatches: tomato, teal, gray, pink,
  chartreuse), REPORTER→DISPATCH (About).
- **Notification settings** — next-notification readout, alerts/day stepper,
  distribution picker (Random: N random in 24h; Semi-random: 1 random per
  24/N-hour window; Regular: every 24/N hours), plus fixed scheduled times.
- **Question settings** — reorderable list, each row prompt + "Type — N
  responses" + ON/OFF toggle; ADD A QUESTION… → editor (prompt, type,
  choices for multi-choice, placeholder).
- **Custom tokens** — vocabulary list with usage counts; rename/delete.
- **Sensor settings** — per-sensor toggles (Location, Weather, Elevation,
  Photos, Audio, Steps, Stairs) + units (temperature F/C, length ft/m).
- **Export settings** — Export as CSV, Export as JSON, Create Backup +
  backup list (restore/delete/share), same explanatory copy structure.

## 4. Sensor capture

Each sensor is an independent structured-concurrency task with a per-sensor
timeout (~10s); failure or disabled toggle → "UNABLE TO DETECT X" /
omitted from the saved report. Sources:

| Sensor | API |
|---|---|
| Location + placemark | CoreLocation (when-in-use) + CLGeocoder |
| Weather | WeatherKit (needs entitlement; degrades gracefully without) |
| Altitude | CLLocation.altitude |
| Steps / stairs | CMPedometer since last report (falls back to midnight) |
| Audio dB | AVAudioRecorder metering, ~2s sample → avg/peak; label scale ("EXTREMELY QUIET" → "EXTREMELY LOUD") |
| Photos since last report | PhotoKit fetch with `creationDate > lastReportDate` (limited-access OK) |
| Battery | UIDevice.batteryLevel |
| Connection | NWPathMonitor (wifi/cellular/none → int) |

Permissions are requested just-in-time mid-flow (as the original does), with
onboarding page 3 priming the ask.

## 5. Notification engine

`UNUserNotificationCenter` local notifications. Scheduler is a pure function
`plan(settings, awakeWindow, seed, day) -> [Date]` (seeded RNG → unit
testable):

- **Random** — N uniformly random times in the awake window.
- **Semi-random** — awake window split into N equal slots, one random time
  per slot.
- **Regular** — every windowLength/N from window start.
- **Scheduled** — fixed times, appended regardless of distribution.
- **Awake/Asleep** — ASLEEP suppresses pending prompts until toggled AWAKE;
  toggling also brackets the awake window used by the planner (like the
  original's wake/sleep reports).

Re-plans on: settings change, awake/asleep toggle, app foreground, and a
daily background refresh. Notifications deep-link into a new report
(`reportImpetus` distinguishes notification vs. manual starts).

## 6. Import / export / sync

- **Import** — Settings → Data. Reads `reporter-export.json` via file
  picker; upserts by `uniqueIdentifier` (idempotent, re-runnable). Token and
  people vocabularies rebuilt from responses. 94 snapshots + 38 questions
  from Robbie's export must import cleanly.
- **Export JSON** — `{"questions": [...], "snapshots": [...]}` byte-
  compatible in structure with the original (superset allowed); share sheet.
- **Export CSV** — one row per report: date, sensor columns, one column per
  question prompt (tokens joined with `|`).
- **Backups** — full JSON (questions + snapshots + vocabularies + settings)
  stored in the app container, listable/restorable/shareable.
- **iCloud sync** — SwiftData CloudKit mirroring, toggleable in settings.
  App is fully functional with sync off or when built without the iCloud
  entitlement (forkers without paid dev accounts).

## 7. Visualizations

Swift Charts, one swipeable page per enabled question on Home, filter bar to
narrow which questions show:

| Type | Visualization |
|---|---|
| Yes/No | full-height stacked proportional bars with % labels (per screenshot) |
| Multi-Choice | horizontal bar distribution of options |
| Number | average + line chart over time |
| Tokens / People | ranked frequency list (top N) |
| Location | ranked top places |
| Note | most recent entries list |

## 8. Error handling

- Sensor failures never block a report; they degrade to "unable to detect".
- Import validates JSON shape and reports per-record failures (skip + count)
  rather than aborting.
- Notification permission denied → banner in notification settings linking
  to system Settings.
- WeatherKit/iCloud entitlement absence detected at runtime → features
  quietly disabled with an explanatory row.

## 9. Testing

- **Unit:** codec round-trip (import Robbie's real export → export →
  semantically equal JSON; real file stays local, CI uses a synthetic
  fixture); scheduler determinism and window math (DST edges); upsert
  idempotency; CSV shape.
- **UI:** XCUITest smoke — complete a report end-to-end with mocked sensors.
- **CI:** GitHub Actions, `xcodebuild test` on iOS simulator.

## 10. Repository

- GitHub `robbiet480/Dispatch`, MIT.
- README: hero screenshots of Dispatch itself, feature list, build steps, entitlement notes
  (WeatherKit, iCloud, HealthKit-free), import instructions, credit to the
  original Reporter app and its creators as inspiration.
- No personal data committed: screenshots and `reporter-export.json` stay
  out of the repo (gitignored).

## 11. Build order (summary; detailed plan follows in writing-plans)

1. Xcode project scaffold, themes, SwiftData models + JSON codec with
   round-trip tests (import CLI-testable early).
2. Report flow with mock sensors → real sensor pipeline.
3. Home, reports list/detail, question settings, token vocabulary.
4. Notification engine.
5. Visualizations.
6. Export/backup/iCloud, onboarding, About, polish, CI, README.
