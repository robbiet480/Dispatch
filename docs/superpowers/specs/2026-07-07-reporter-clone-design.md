# Dispatch — a modernized, open-source Reporter clone (design spec)

**Date:** 2026-07-07
**Status:** Approved by Robbie (pending spec review)

## 1. Product

Dispatch is a native SwiftUI iPhone app that recreates — and modernizes —
the self-tracking loop of Nicholas Felton's discontinued Reporter app:

1. Prompts arrive via randomly timed notifications **and modern triggers**
   (arriving/leaving places, waking up, finishing a workout).
2. Starting a report auto-captures context: location, weather, altitude,
   ambient audio level, photo count, battery, connection, and a
   **HealthKit sensor hub** (steps, flights, heart rate, HRV, sleep,
   workouts, medications, caffeine — each toggleable).
3. You answer a personalized, ordered list of questions (7 types). Yes/No
   and multi-choice questions are answerable **directly from the
   notification**. Mood-type questions write **State of Mind** samples to
   Apple Health.
4. Reports are stored locally (SwiftData), synced via iCloud, visualized
   in-app, summarized weekly by the **on-device LLM**, and exportable as
   JSON/CSV.

**Minimum deployment target: iOS 26** (needed for Foundation Models; also
simplifies everything else — no availability branching). Open source on
GitHub under MIT with an original name ("Dispatch") and icon. The
interaction model and flat color-themed aesthetic follow the original; no
assets, artwork, or the "Reporter" name are copied.

Reference material (not committed): 21 UI screenshots and
`reporter-export.json` (94 snapshots, 38 questions) from Robbie's original
install.

## 2. Data model

SwiftData models, CloudKit-mirrored (all properties optional or defaulted,
no unique constraints; dedupe by `uniqueIdentifier` in code).

**Schema is v2** — a deliberate superset/break of the original export
format. `"schemaVersion": 2` at the export root; a legacy importer ingests
the v1 format (Robbie's real export) one-way.

### Question

| Field | Notes |
|---|---|
| `uniqueIdentifier` | string (UUID or `default-question-N`) |
| `prompt` | display text |
| `questionType` | int enum, below (kept v1-compatible) |
| `placeholderString` | optional (e.g. "No one", "50.00") |
| `choices` | `[String]` — v2 field; v1 export lacked it (`answers: null`), so v1 imports seed empty and options are re-entered in Question Settings |
| `sortOrder`, `isEnabled` | v2 fields |
| `stateOfMindKind` | v2, optional: maps a multi-choice question's options onto an HKStateOfMind valence scale (e.g. anxiety None→Extreme). Present ⇒ answers write State of Mind samples |
| `notificationAnswerable` | v2, derived: yes/no & multi-choice ⇒ answerable from the notification |
| `reportKinds` | v2: which report kinds show this question — subset of `{regular, wake, sleep}`, default `{regular}` (e.g. "How did you sleep?" → `{wake}`) |

Question types (verified against v1 export): 0=Tokens, 1=Multi-Choice,
2=Yes/No, 3=Location, 4=People, 5=Number, 6=Note.

### Report (snapshot)

v1 fields kept: `uniqueIdentifier`, `date`, `sectionIdentifier`, `battery`,
`altitude`, `background`, `draft`, `reportImpetus`, `connection`,
`audio {avg, peak}`, `location {lat/lon/speed/course/accuracy, placemark}`,
`weather` (WeatherKit-populated subset of the v1 blob), `photoSet`.

v2 changes:
- `steps` moves into `health` (below); v1 importer maps it.
- `health`: array of typed readings captured at report time —
  `{type, value, unit, startDate?, endDate?}` — covering steps and flights
  since last report, latest/avg heart rate, HRV, resting HR, last night's
  sleep duration & stages summary, workouts today (type/duration/energy),
  medications logged today, caffeine total. Array-of-readings keeps the
  schema open for new HealthKit types without migration.
- `trigger` replaces the overloaded `reportImpetus` semantics (v1 value
  preserved on import): `manual | notification | visitArrival |
  visitDeparture | wake | workoutEnd | widget | control | intent`.
- `stateOfMindSampleIDs`: HealthKit UUIDs written from this report's
  answers (for dedupe/undo).
- `focus`: optional `{label?, isFocused}` — active Focus at report time
  (label when a Focus Filter is configured, boolean otherwise).
- `kind`: `regular | wake | sleep`. The original's AWAKE/ASLEEP toggle
  filed wake and sleep reports; Dispatch files them automatically from the
  sleep-derived window (manual toggle still works) and shows only the
  questions targeted at that kind.
- `timeZone`: IANA identifier captured per report — the v1 export spans
  Oakland and NYC, and day-grouping/stats are wrong without it. v1 imports
  derive it from the date's UTC offset + location where possible.
- `isBackdated`: bool — report filed after the fact (see backfill, §3);
  excluded from response-latency stats but included everywhere else.

### Response

Unchanged from v1 (join key `questionPrompt`, one payload):
`tokens` (types 0,4), `answeredOptions` (1,2), `locationResponse` (3),
`numericResponse` (5), `textResponses` (6), or none = skipped.

### Vocabularies

`Token` and `Person` entities with usage counts (Custom Tokens screen).

## 3. Screens

Same surface as the original, plus modern rows:

- **Onboarding** — 4-page carousel; original-but-similar geometric
  triangle-grid illustrations in SwiftUI Canvas; permission priming.
- **Home** — theme-colored; hexagon; REPORT button; AWAKE/ASLEEP indicator
  (now auto-driven, see §5, tap to override); swipeable per-question
  visualization pages + filter bar; **weekly digest card** (see §7).
- **Report flow** — sensor-capture checklist page ("GETTING WEATHER…",
  "27,851 STEPS TAKEN", "UNABLE TO DETECT X" on failure) with first
  question below; then one question per page; progress bar; CANCEL/dots/NEXT.
- **Reports list** — swipeable stats header (reports/days/avg;
  tokens/locations/people), day-grouped rows (time + place, wake/sleep
  glyphs), detail view now including health readings, Focus, and trigger
  type. **Search bar**: full-text over note text, tokens, people, and place
  names. **Backfill**: a "+" entry point files a report for an earlier
  time (date picker, `isBackdated`, sensors skipped except what HealthKit
  can answer historically).
- **Settings** — SCHEDULE (Notifications, Triggers), SURVEY (Questions,
  Sensors), DATA (Export, Import, iCloud, nightly auto-backup toggle),
  PRIVACY (App lock via Face ID/LocalAuthentication), INTERFACE (5 theme
  swatches), ABOUT.
- **Notification settings** — alerts/day, distribution (Random /
  Semi-random / Regular), fixed times, next-alert readout.
- **Trigger settings** (new) — toggles: prompt on arrival, on departure,
  on wake, after workouts; per-trigger cooldown.
- **Question settings** — reorder, toggle, add/edit (prompt, type, choices,
  placeholder, State of Mind mapping for multi-choice).
- **Custom tokens** — vocabulary with usage counts.
- **Sensor settings** — toggles: Location, Weather, Elevation, Photos,
  Audio, Battery + a HealthKit section (Steps, Flights, Heart, HRV, Sleep,
  Workouts, Medications, Caffeine); units (°F/°C, ft/m).
- **Export settings** — Export CSV / Export JSON (v2) / Import (v1 or v2) /
  backups list.

## 4. Context capture

Independent structured-concurrency tasks, per-sensor ~10s timeout; failure
or disabled toggle degrades to "UNABLE TO DETECT X" / omission.

| Source | API |
|---|---|
| Location + placemark | CoreLocation (when-in-use + always for visits) + CLGeocoder |
| Weather | WeatherKit (entitlement; degrades gracefully) |
| Altitude | CLLocation.altitude |
| Audio dB | AVAudioRecorder metering ~2s → avg/peak + label scale |
| Photos since last report | PhotoKit `creationDate > lastReportDate` |
| Battery / connection | UIDevice / NWPathMonitor |
| **All health metrics** | HealthKit statistics + sample queries (steps, flights, HR, HRV, resting HR, sleep, workouts, medications, caffeine). No CoreMotion anywhere. |
| **State of Mind** | HKStateOfMind: written from mapped questions; latest sample also read as context |
| **Focus** | Focus Filter (`SetFocusFilterIntent`) records the active Focus's user-assigned label as it changes (one-time per-Focus setup in Settings); falls back to the `INFocusStatusCenter` focused/not-focused boolean (Focus Status entitlement). Captured as a context row; Focus-change *prompting* is already covered by Shortcuts automations → `StartReportIntent` |

Permissions requested just-in-time mid-flow; onboarding primes them.

## 5. Prompting engine

Two layers, both funnel into one `PromptScheduler`:

**Timed (v1 parity)** — pure function
`plan(settings, awakeWindow, seed, day) -> [Date]`; Random / Semi-random /
Regular distributions + fixed scheduled times; seeded RNG for tests.

**Event triggers (v2)** —
- **Visits**: CLMonitor/CLVisit arrival & departure → prompt (per-trigger
  cooldown, quiet during asleep window).
- **Wake/sleep**: awake window derived from last night's HealthKit sleep
  samples (fallback: manual toggle, which also records wake/sleep like the
  original). Waking triggers an optional morning prompt.
- **Workout end**: HKObserverQuery on workouts → prompt.
- **App Intents**: `StartReportIntent`, `AnswerQuestionIntent`,
  `ToggleAwakeIntent` exposed to Shortcuts/Siri so arbitrary user
  automations (charging, Focus change, CarPlay) can trigger reports.

**Interactive notifications** — yes/no and multi-choice prompts carry
UNNotificationActions; answering from the notification creates a minimal
report (`trigger: notification`, sensors captured in a background task,
remaining questions skipped). Every prompt also carries a **Snooze 15m**
action. Time-sensitive interruption level.

**Wake/sleep reports** — the sleep-derived window (or manual toggle) files
`wake` and `sleep` kind reports showing only questions targeted at those
kinds, matching the original's behavior.

Re-plans on: settings change, awake window change, foreground, daily
background refresh.

## 6. Import / export / sync

- **Import**: file picker; v1 (original Reporter export — Robbie's 94
  snapshots + 38 questions must import cleanly) and v2; upsert by
  `uniqueIdentifier`, idempotent; vocabularies rebuilt from responses.
- **Export**: v2 JSON (`schemaVersion: 2`); CSV one row per report
  (health readings as columns, tokens `|`-joined); share sheet.
- **Backups**: full v2 JSON incl. settings; listable/restorable/shareable.
  Optional **nightly auto-backup** (BGTaskScheduler) writing to an iCloud
  Drive folder so a plaintext copy always exists outside the SwiftData
  store.
- **Spotlight**: reports indexed via CoreSpotlight (date, place, note
  snippets, tokens) so they surface in system search; index rebuilt on
  import/restore.
- **iCloud**: SwiftData CloudKit mirroring, toggleable; app fully functional
  without the entitlement (forkers without paid accounts — WeatherKit,
  iCloud, and even HealthKit degrade to off).

## 7. Visualizations & intelligence

**Swift Charts** per-question pages with filter bar: Yes/No → full-height
stacked % bars; Multi-Choice → option distribution; Number → average +
line; Tokens/People → ranked frequency; Location → top places; Note →
recents. Health readings get sparkline rows on the report detail.

**Weekly digest (Foundation Models, on-device)**: a scheduled Friday job
feeds the week's reports into the on-device LLM → 3–5 sentence natural-
language summary + notable correlations ("anxiety was Low in 80% of
reports where you'd worked out"), rendered as a Home card and a
notification. Also: token auto-suggestion for note answers. Zero cloud;
feature hides gracefully if the model is unavailable (low storage, etc.).

## 8. Widgets & Control Center

WidgetKit: home-screen + lock-screen widgets (streak, reports today,
next-prompt countdown; tap → new report) and a Control Center control
(one-tap Start Report). All deep-link via App Intents from §5.

## 9. Error handling

- Sensor/HealthKit failures never block a report (degrade + omit).
- Import validates shape; per-record skip + error count, never aborts.
- Notification permission denied → settings banner linking to Settings.
- Missing entitlements (WeatherKit/iCloud/HealthKit) detected at runtime →
  feature rows disabled with explanation.
- State of Mind writes are best-effort; failures logged, never surfaced
  mid-survey.

## 10. Testing

- **Unit**: v1→model→v2 import/export round-trip against Robbie's real
  export locally (synthetic fixture in CI); scheduler determinism + DST
  window math; trigger cooldown logic; upsert idempotency; CSV shape;
  State of Mind mapping.
- **UI**: XCUITest smoke — complete a report with mocked sensors.
- **CI**: GitHub Actions, `xcodebuild test` on iOS 26 simulator.

## 11. Repository

- GitHub `robbiet480/Dispatch`, MIT.
- README: screenshots of Dispatch itself, feature list, build steps,
  entitlement notes, v1-import instructions, credit to the original
  Reporter app and its creators as inspiration.
- No personal data committed (screenshots + export gitignored).

## 12. Platform requirements

- **Privacy manifest** (`PrivacyInfo.xcprivacy`) covering all data types
  collected, plus complete purpose strings for location, HealthKit,
  microphone, photos, contacts, Focus status, and notifications.
- **App lock**: optional Face ID/passcode gate (LocalAuthentication) on
  launch and on returning from background after a grace period.
- **Accessibility**: Dynamic Type throughout, VoiceOver labels/values on
  custom charts and the hexagon/report controls, sufficient contrast in
  all five themes.
- **Background budget**: BGTaskScheduler tasks (daily re-plan, nightly
  auto-backup, weekly digest) coalesced and tolerant of iOS deferrals.

## 13. v2 backlog (documented, not built)

Apple Watch app; Live Activities (pending-report countdown); Journaling
Suggestions API integration; calendar (EventKit) and now-playing context
sensors; motion-activity context; voice dictation for note answers;
Dropbox export; **conditional questions** (branch on a prior answer);
**correlation explorer** (pivot any question against another /
location / health metric).

## 14. Build order (summary; detailed plan follows in writing-plans)

1. Scaffold, themes, SwiftData models, v1/v2 codecs + round-trip tests.
2. Report flow with mocked context → real capture pipeline (HealthKit hub).
3. Home, reports list/detail, question settings, vocabularies.
4. Prompting engine: timed → interactive notifications → event triggers →
   App Intents.
5. Visualizations; State of Mind write-through.
6. Widgets + Control Center; weekly digest.
7. Search + Spotlight, app lock, backfill.
8. Export/backup/iCloud + auto-backup, onboarding, About, CI, README,
   privacy manifest, accessibility pass, polish.
