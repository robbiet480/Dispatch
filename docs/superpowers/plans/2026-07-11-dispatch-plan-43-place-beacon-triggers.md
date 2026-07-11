# Dispatch Plan 43: Place-specific & iBeacon prompt triggers (CLMonitor)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (issues #56 + #60):** two new prompt-group trigger sources that share one
observer and one delay/cancel machinery:

- **#56 — place-specific arrival/departure:** "prompt me 30 minutes after
  arriving at the office", "prompt me 10 minutes after leaving the gym". A
  picked coordinate + radius, a direction (arrival / departure), and a delay
  (0/5/10/15/30/60 min). A contradicting event before the delay elapses
  cancels the pending prompt.
- **#60 — iBeacon proximity:** "prompt me when I sit down at my desk" (beacon
  on the desk). A registered beacon (UUID + optional major/minor + friendly
  name), same direction + delay + cancel semantics.

Both are siblings of the shipped visit-arrival trigger (plan 16): event-driven
prompts posted by an observer, editor-contextual **Always** location
authorization (the same purpose string plan 16 already added — NO new
entitlement), test-gated, refreshed on group edits and remote-change sync.

## One-plan decision

**One plan, one branch.** #56 and #60 differ only in the CLMonitor *condition
kind* — a `CircularGeographicCondition` vs a `BeaconIdentityCondition`. They
share literally everything else: one `CLMonitor` instance, one event stream,
one delay/cancel engine, one condition budget, one editor family, one set of
report triggers, the same authorization. Splitting them would duplicate the
observer and the plumbing. The tasks below build the shared kit first, then the
shared observer, then place editor, then beacon editor + settings surface.

## Architecture

**Modern monitoring — `CLMonitor` (iOS 17+), not region delegates.**
`CLCircularRegion` / `CLBeaconRegion` and the `CLLocationManagerDelegate`
region callbacks are deprecated as of iOS 26. `CLMonitor` replaces them: you
create a named monitor, `add(_:identifier:)` conditions, and consume a single
`monitor.events` async stream that reports each condition's state
(`.satisfied` / `.unsatisfied` / `.unknown`) with background wake. One monitor
owns BOTH condition kinds — geographic (#56) and beacon (#60) — so a single
`MonitorObserver` handles the whole feature.

**Delay/cancel — pure kit engine, OS-held timer.** A `Task.sleep(30 min)` does
not survive app suspension/termination, so the delay is NOT an in-process
timer. On a fire-direction event the observer schedules an ordinary local
notification with a `UNTimeIntervalNotificationTrigger(delay)` — the OS holds
the timer and wakes to deliver even if Dispatch is terminated. A contradicting
event (the app is woken by CLMonitor for it) simply removes that pending
request. The *decision* — schedule vs cancel vs ignore, and the fire date — is
pure and lives in DispatchKit (`MonitorTriggerEngine`), TDD'd under
`swift test`; the observer only executes it.

**Replan-safe identifier prefix.** The replan removal batch in
`NotificationScheduler.replanNow` sweeps ALL `prompt-`/`gprompt-`/`nag-`/
`digest-`/`webhook-failed-` pending requests before re-adding the timer/calendar
schedule. A delayed place/beacon prompt is scheduled OUTSIDE the replan (by the
observer, reactively) and must survive replans that fire during its delay
window — so it uses a NEW prefix **`mprompt-`** (`mprompt-<groupID>-<stamp>`)
that the replan batch does NOT touch. The observer owns its lifecycle: schedule
on the fire event, remove-by-`mprompt-<groupID>-`-prefix on the contradicting
event, and sweep `mprompt-` for groups no longer enabled/monitored on
`refresh()`. `promptSource` recognizes `mprompt-` as a group prompt for the
"next notification" hero.

**Condition budget (~20).** CLMonitor's monitored-condition budget is limited
and shared across places AND beacons. Only ENABLED place/beacon groups register
a condition; `MonitorConditionBudget` (pure, kit, tested) caps the combined set
in sortOrder and reports which groups were dropped, so the editor/list can warn
"not monitored — over the limit". Replanned on group edits, exactly the
`refresh()` discipline VisitObserver/CalendarEventObserver already use.

## Tech Stack

- **CoreLocation `CLMonitor`** (iOS 17+): `CLMonitor(_:)` async factory,
  `CLMonitor.CircularGeographicCondition(center:radius:)`,
  `CLMonitor.BeaconIdentityCondition(uuid:)` / `(uuid:major:)` /
  `(uuid:major:minor:)`, `add(_:identifier:)`, `remove(_:)`, `identifiers`,
  and the `monitor.events` `AsyncSequence` yielding `CLMonitor.Event` with
  `.identifier` and `.state`.
- **CoreLocation `CLLocationManager`** for Always authorization only (reused
  from plan 16 — `requestAlwaysAuthorization`, `NSLocationAlwaysAndWhenInUse`
  purpose string already present).
- **UserNotifications** `UNTimeIntervalNotificationTrigger` (the delay) + nil
  trigger (delay 0 = immediate), content-addressed `mprompt-` identifiers.
- **DispatchKit** pure logic: `MonitorTriggerEngine`, `MonitorConditionBudget`,
  the trigger config structs and their JSON codecs.
- **SwiftData** additive optional fields on `PromptGroup` (CloudKit-safe).
- **XcodeGen** — no project.yml change needed for auth (the Always purpose
  string exists); beacon monitoring rides the same location authorization.

## Threat/limits model

- **Beacon spoofing is out of scope.** iBeacons broadcast an unauthenticated
  UUID/major/minor; anyone can clone one. A cloned desk-beacon would fire a
  self-report prompt — a nuisance at worst, no data exfiltration (the prompt
  only asks the user their own questions on-device). Documented, not defended.
- **Location stays on-device.** Coordinates/radii are stored in SwiftData
  (CloudKit-synced to the user's own account only) and never leave the device
  otherwise; the v2 export carries them for the user's own backup. No new
  network surface.
- **Condition budget exhaustion fails quiet:** groups past the ~20 cap simply
  don't register and show an inline "not monitored" hint — they never crash or
  silently pretend to be armed.

## Design decisions (decide + log)

- **Two schedule kinds, one config shape.** `GroupScheduleKind` gains
  `.placeTrigger` and `.beaconTrigger` (distinct so insights/charts slice #56
  vs #60 and the editor shows the right controls). Both carry a shared
  `MonitorDirection` (`arrival`/`departure`), `delayMinutes`, and
  `cancelOnContradiction`; place adds a `MonitorPlaceRegion`
  (lat/lon/radius/name), beacon adds a `MonitorBeaconIdentity`
  (uuid/major?/minor?/name?). Rejected: one unified `.monitored` kind — it
  would force a runtime condition-type tag and muddy the editor switch; two
  kinds keep each editor arm and each `ReportTrigger` clean.
- **Storage — discrete shared scalars + one JSON blob per condition.**
  Additive optionals on `PromptGroup`: `monitorDirectionRaw: String?`,
  `monitorDelayMinutes: Int?`, `monitorCancelsOnContradiction: Bool?`,
  `placeRegionJSON: String?`, `beaconIdentityJSON: String?` (the region/beacon
  as JSON, the `scheduledTimesJSON`/`calendarIdentifiersJSON` codec precedent).
  All CloudKit-safe. Unknown/missing payload for the resolved kind →
  `.disabled` (the calendar-rule forward-compat precedent: never fires rather
  than misfires; raws preserved on write-back).
- **Direction = condition state.** Arrival fires on `.satisfied` (entered
  region / in beacon range), departure fires on `.unsatisfied`. The
  contradicting state cancels a pending prompt when `cancelOnContradiction`
  (default true). `.unknown` is ignored (CLMonitor emits it when a condition's
  state can't yet be determined — never a fire or a cancel).
- **Delay presets:** 0/5/10/15/30/60 min (`MonitorDelay.allowedMinutes`),
  matching the issue. 0 = immediate (nil-trigger delivery, the visit-arrival
  path); >0 = `UNTimeIntervalNotificationTrigger`. `cancelOnContradiction`
  defaults ON and is configurable (issue #56 asks "configurable?").
- **Radius floor 100 m** (`MonitorDelay.floorRadiusMeters`): CLMonitor
  geographic callbacks are unreliable below ~100 m. `MonitorPlaceRegion`
  clamps radius to the floor at construction; the editor's radius control has
  the same floor. Logged: honest radius over false precision.
- **Delayed prompts use the `mprompt-` prefix** (see Architecture) — replan-
  safe, observer-owned, `promptSource`-recognized, NOT swept by the replan
  batch. Content-addressed by fire minute so a duplicate CLMonitor delivery of
  the same event dedupes.
- **Report attribution:** `ReportTrigger` gains `.placeArrival`,
  `.placeDeparture`, `.beaconArrival`, `.beaconDeparture` (additive raws; older
  builds fall back to `.manual` via the existing `ReportTrigger(rawValue:) ??
  .manual` read — the visit/workout norm). userInfo markers on the `mprompt-`
  content carry which of the four fired so the delegate maps the tap-through
  `SurveyRequest` trigger. The beacon/place friendly name rides the report's
  existing trigger metadata path (pairs with #48 sensor deltas as the issue
  notes) via the group name — no new report field.
- **Budget replan discipline mirrors the observers already shipped:**
  `MonitorObserver.refresh()` recomputes enabled monitored groups, allocates
  the ~20 budget in sortOrder, `add`s/`remove`s CLMonitor conditions to match,
  and sweeps orphaned `mprompt-` requests. Called at launch, onAppear,
  scene-active, group edits, remote-change sync — every `visitObserver.refresh()`
  site.
- **Authorization = Always, reused.** Beacon AND geographic CLMonitor
  conditions need Always location to wake in the background. The plan-16
  purpose string + editor-contextual `requestAlwaysAuthorization()` flow is
  reused verbatim (a `VisitObserver`-style requester); no new purpose string,
  no new entitlement. Denied/when-in-use → inline "needs Always" hint, group
  doesn't fire (the visit precedent).
- **watchOS: iPhone-only** (issue #60): CLMonitor beacon support on watch is
  limited; monitoring runs on iPhone and the scheduled `mprompt-` forwards to
  the watch like any other prompt. No watch-side code.
- **Beacon settings surface (#60):** a "Beacons" list in Settings showing known
  beacons (from beacon groups) with a live "in range?" indicator sourced from
  the observer's last-seen condition state — setup-debugging aid, read-only.

## Observable Acceptance Criteria

- The group editor Schedule picker (`group-schedule-kind`) offers **When I
  arrive at / leave a place** and **When I'm near a beacon** alongside the
  existing kinds.
- Picking **When I arrive at / leave a place** reveals a direction control
  (`group-place-direction`, Arrival / Departure), a radius control
  (`group-place-radius`, floored at 100 m), and a delay picker
  (`group-monitor-delay`, values 0/5/10/15/30/60). Picking the schedule
  triggers the system **Always** location prompt once (device only); without
  Always the editor shows the `group-visit-needs-always`-style hint.
- Picking **When I'm near a beacon** reveals a UUID field
  (`group-beacon-uuid`), optional major/minor fields (`group-beacon-major` /
  `group-beacon-minor`), a friendly-name field (`group-beacon-name`), the same
  direction + delay controls, and the same Always hint when unauthorized.
- The groups list row for a place/beacon group shows its schedule summary
  (e.g. `Arrive at Office · +30m`, `Near Desk beacon`) and, without Always
  location, the yellow `group-row-needs-always` hint (won't fire).
- A group dropped past the ~20-condition budget shows an inline
  `group-row-over-budget` hint ("Not monitored — too many location/beacon
  groups").
- Settings shows a **Beacons** row (`settings-beacons`) opening a list of known
  beacons; each row (`beacon-row`) shows the friendly name and a live in-range
  indicator (`beacon-in-range`) when monitoring is active.

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement →
  `swift test` green, per task.
- Additive v2 format only: new `V2PromptGroup` fields optional, omitted when
  nil; unknown raws imported leniently; NO schemaVersion bump; NEVER repurpose
  existing `scheduleKindRaw`/`ReportTrigger` raws.
- No new entitlements and no signing/entitlement/profile churn; the Always
  purpose string already exists (plan 16). If anything needs an entitlement,
  STOP that item, document, continue with the rest.
- Test gating absolute: `--mock-sensors`/`--ui-testing` → no CoreLocation, no
  CLMonitor, no permission dialogs (the observer reads authorized with no
  conditions, the VisitObserver posture).
- No exhaustive-switch `default:` added to `GroupSchedule`/`GroupScheduleKind`/
  `ReportTrigger` — every new case is handled explicitly.
- Suites green before every commit; scoped commit + push per task;
  `git pull --rebase` before starting/pushing. Do NOT bump the build number.
- Every uncertain CLMonitor platform claim verified during implementation with
  the finding recorded in a code comment (house style: the VisitObserver
  background-modes citation).

---

### Task 1: Kit — schedule kinds, trigger configs, delay/cancel engine, budget, trigger, v2

**Files:**
- Modify: `Sources/DispatchKit/Models/PromptGroup.swift` (two kinds + cases +
  five fields + codec), `Sources/DispatchKit/Models/Values.swift` (four
  `ReportTrigger` cases), `Sources/DispatchKit/Prompting/GroupPlanner.swift`
  (the event-kind `[]` row), `Sources/DispatchKit/Prompting/NotificationIdentifiers.swift`
  (`monitorPromptPrefix` + marker keys + `promptSource` arm),
  `Sources/DispatchKit/V2/V2Models.swift` + `V2Exporter.swift` +
  `Sources/DispatchKit/Import/V2Importer.swift` (five group fields)
- Create: `Sources/DispatchKit/Prompting/MonitorTrigger.swift` (config structs
  + codecs), `Sources/DispatchKit/Prompting/MonitorTriggerEngine.swift`
  (decision), `Sources/DispatchKit/Prompting/MonitorConditionBudget.swift`
- Test: create `Tests/DispatchKitTests/MonitorTriggerEngineTests.swift`,
  `Tests/DispatchKitTests/MonitorConditionBudgetTests.swift`,
  `Tests/DispatchKitTests/MonitorTriggerTests.swift`; extend
  `PromptGroupTests.swift`, `GroupPlannerTests.swift`,
  `NotificationIdentifiersTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `MonitorDirection: String, Codable, Sendable, CaseIterable` — `.arrival`,
  `.departure`
- `MonitorPlaceRegion: Equatable, Sendable, Codable` — `latitude/longitude/
  radius/name`, radius clamped to `MonitorDelay.floorRadiusMeters` at init
- `MonitorBeaconIdentity: Equatable, Sendable, Codable` —
  `uuid/major?/minor?/name?`
- `PlaceTrigger`, `BeaconTrigger` — `{condition, direction, delayMinutes,
  cancelOnContradiction}`; each with a failable init from stored fields +
  a JSON accessor
- `MonitorDelay.allowedMinutes = [0,5,10,15,30,60]`,
  `MonitorDelay.floorRadiusMeters = 100`
- `GroupScheduleKind.placeTrigger` (raw `"placeTrigger"`), `.beaconTrigger`
  (raw `"beaconTrigger"`); `GroupSchedule.placeTrigger(PlaceTrigger)`,
  `.beaconTrigger(BeaconTrigger)`
- `MonitorConditionState: Sendable, Equatable` — `.satisfied/.unsatisfied/
  .unknown`; `MonitorTriggerOutcome` — `.schedule(fireDate:)/.cancelPending/
  .ignore`; `MonitorTriggerEngine.outcome(direction:delayMinutes:
  cancelOnContradiction:state:eventDate:)`
- `MonitorConditionBudget.defaultLimit = 20`,
  `.allocate(groupIDs:limit:) -> (registered:[String], dropped:[String])`
- `PromptGroup.monitorDirectionRaw/monitorDelayMinutes/
  monitorCancelsOnContradiction/placeRegionJSON/beaconIdentityJSON`
- `ReportTrigger.placeArrival/.placeDeparture/.beaconArrival/.beaconDeparture`
- `NotificationIdentifiers.monitorPromptPrefix = "mprompt-"`,
  `.placeArrivalKey/.placeDepartureKey/.beaconArrivalKey/.beaconDepartureKey`
- `V2PromptGroup.monitorDirection/monitorDelayMinutes/
  monitorCancelsOnContradiction/placeRegion/beaconIdentity` (all optional)

- [ ] **Step 1: Write the failing tests.**
  - `MonitorTriggerEngineTests`: arrival + `.satisfied` → `.schedule(event +
    delay·60)`; arrival + `.unsatisfied` + cancel-on → `.cancelPending`;
    arrival + `.unsatisfied` + cancel-off → `.ignore`; departure inverts
    (fires on `.unsatisfied`, cancels on `.satisfied`); `.unknown` always
    `.ignore`; delay 0 → fireDate == eventDate.
  - `MonitorConditionBudgetTests`: under limit → all registered, none dropped;
    over limit → first `limit` registered (sortOrder priority), rest dropped;
    limit 0 → all dropped; empty → empty.
  - `MonitorTriggerTests`: `MonitorPlaceRegion` clamps radius below 100 to 100;
    `PlaceTrigger`/`BeaconTrigger` round-trip through their stored-field
    initializers; unknown/missing payload → nil init.
  - `PromptGroupTests`: `.placeTrigger` and `.beaconTrigger` round-trip through
    `schedule` writing `scheduleKindRaw` + the right JSON/scalar fields;
    a `.placeTrigger` group with corrupt `placeRegionJSON` resolves `.disabled`
    and preserves raws; v2 byte-round-trip for one place + one beacon group
    (assert the five new keys present for them, ABSENT for non-monitor groups);
    a newer-build v2 fixture carrying `placeTrigger`/`beaconTrigger` imports
    leniently.
  - `GroupPlannerTests`: `.placeTrigger`/`.beaconTrigger` plan `[]`.
  - `NotificationIdentifiersTests`: `mprompt-<uuid>-<stamp>` → `.promptGroup`
    with the right groupID; `mprompt-` is not a nag/digest.
- [ ] **Step 2: `swift test` — expect FAIL** (kinds/configs/engine/budget/
  fields/triggers don't exist).
- [ ] **Step 3: Implement.** New `MonitorTrigger.swift` (structs + `MonitorDelay`
  + codecs), `MonitorTriggerEngine.swift`, `MonitorConditionBudget.swift`.
  `PromptGroup`: append two enum cases; add five optional fields; extend the
  `schedule` getter (resolve each kind through the trigger's failable init →
  `.disabled` on nil) and setter (write kind raw + scalars + JSON, nil the
  other kind's JSON). `GroupPlanner`: join the `[]` row + doc. `Values.swift`:
  four `ReportTrigger` cases. `NotificationIdentifiers`: `monitorPromptPrefix`,
  four marker keys, `promptSource` `mprompt-` arm (same parse as `gprompt-`).
  V2: five optional fields + exporter (decode JSON→struct, nil-collapse) +
  importer (encode struct→JSON).
- [ ] **Step 4: `swift test` — expect PASS** (whole kit suite; the app target
  won't build until Tasks 2–4 grow the exhaustive `GroupSchedule` switches —
  expected, the plan-26/31 adjacent-commit convention).
- [ ] **Step 5: Commit** — `feat(kit): place/beacon schedule kinds, delay/cancel
  engine, condition budget` → push.

### Task 2: App — MonitorObserver (CLMonitor, both condition kinds, delay/cancel)

**Files:**
- Create: `App/Sources/Providers/MonitorObserver.swift`
- Modify: `App/Sources/DispatchApp.swift` (construction next to
  `madeVisitObserver`, `.environment`, refresh at every `visitObserver.refresh()`
  site)

**Interfaces (produced):**
- `MonitorObserver` (`@MainActor @Observable`): `authorizationStatus:
  CLAuthorizationStatus`, `hasAlwaysAuthorization: Bool` (test env true),
  `requestAlwaysAuthorization() async`, `refresh()`,
  `droppedGroupIDs: Set<String>` (over-budget, for the row hint),
  `beacons() -> [(id, name, inRange: Bool?)]` (for the settings surface),
  and the CLMonitor event loop applying `MonitorTriggerEngine`.

- [ ] **Step 1: Observer skeleton.** Mirror VisitObserver: `@MainActor
  @Observable`, `ModelContainer` + `AwakeStore` + focus-filter defaults +
  `isTestEnvironment` injected, launch-registered, idempotent `refresh()`,
  reuse `AlwaysAuthorizationRequester`/`OneShotResumeGuard` verbatim for the
  Always upgrade. Test env: `refresh()` no-ops, `hasAlwaysAuthorization` true,
  no CLMonitor touched.
- [ ] **Step 2: CLMonitor lifecycle.** Lazily create `CLMonitor("DispatchMonitor")`
  (async factory — hop as needed). `refresh()`: fetch enabled place+beacon
  groups in sortOrder, `MonitorConditionBudget.allocate` (limit 20), diff
  desired vs `monitor.identifiers` and `add`/`remove` conditions keyed by
  group `uniqueIdentifier` (`CircularGeographicCondition` for place,
  `BeaconIdentityCondition` for beacon), record `droppedGroupIDs`, and sweep
  orphaned `mprompt-<groupID>-` pending requests for groups no longer
  monitored. Verify every CLMonitor API name against the SDK during build;
  cite the deprecation + event-state contract in the type doc.
- [ ] **Step 3: Event loop → engine → notification.** A launch-started `Task`
  consuming `for try await event in monitor.events`: map `event.identifier`
  back to its group, read its trigger config, call
  `MonitorTriggerEngine.outcome(...)` with `event.state` mapped to
  `MonitorConditionState` at `Date()`; on `.schedule(fireDate)` — awake-gated,
  focus-filter-gated (the VisitObserver reads) — build an `mprompt-<groupID>-
  <stamp>` request (delay 0 → nil trigger; >0 → `UNTimeIntervalNotification
  Trigger(max(1, fireDate.timeIntervalSinceNow))`) with the right
  place/beacon-direction marker userInfo, `center.add`; on `.cancelPending` —
  `removePendingNotificationRequests` for the group's `mprompt-` ids; on
  `.ignore` — nothing. Track last-seen state per identifier for the beacon
  in-range readout.
- [ ] **Step 4: DispatchApp wiring.** Construct beside `madeVisitObserver`, set
  `.environment(monitorObserver)`, add `monitorObserver.refresh()` at every
  `visitObserver.refresh()` call site (launch, onAppear, scene-active,
  remote-change).
- [ ] **Step 5: Verify** — `swift test`, `xcodebuild build-for-testing` (app
  builds only after Tasks 3/4 grow the editor switches — land as adjacent
  commits, plan-31 convention; note in report).
- [ ] **Step 6: Commit** — `feat: CLMonitor observer for place/beacon prompts`
  → push.

### Task 3: App — place-trigger editor arm + scheduler trigger mapping

**Files:**
- Modify: `App/Sources/Settings/PromptGroupsView.swift` (place arm), 
  `App/Sources/Notifications/NotificationScheduler.swift` (`didReceive` maps
  the four new markers to the `ReportTrigger`s; ordering preserved:
  workout > visit > calendar > place > beacon > `.notification`)

- [ ] **Step 1: Schedule kind + summary.** `EditableScheduleKind` gains
  `.placeTrigger` ("When I arrive at / leave a place"); `GroupSchedule.summary`
  gains a place case (`Arrive at <name> · +30m` / `Leave <name> · +10m`); the
  editor `init` seeds place drafts (direction/delay/radius/lat/lon/name) from
  the group; `draftSchedule` builds `.placeTrigger(...)`.
- [ ] **Step 2: Editor section + auth.** `scheduleSection`'s switch gains the
  place arm: footnote, direction Picker (`group-place-direction`), delay Picker
  (`group-monitor-delay`, `MonitorDelay.allowedMinutes`), radius control
  (`group-place-radius`, floored), a cancel-on-contradiction toggle
  (`group-monitor-cancel`), and a coordinate entry (reuse the location-answer
  vocabulary for naming/suggestions per #56 — minimal: lat/lon fields + name,
  a map picker deferred). `onChange(of: scheduleKind)` requests Always when
  `.placeTrigger` and `!hasAlwaysAuthorization` (the visit twin). Row hint +
  over-budget hint (`group-row-over-budget`).
- [ ] **Step 3: Scheduler trigger mapping.** `didReceive` reads the four
  markers and extends the trigger resolution chain in the documented order.
- [ ] **Step 4: Verify** — `swift test`, `xcodebuild build-for-testing`. Commit
  `feat: place-trigger prompt groups — editor + delay/cancel` → push.

### Task 4: App — beacon editor arm + Beacons settings surface + wrap

**Files:**
- Modify: `App/Sources/Settings/PromptGroupsView.swift` (beacon arm),
  `App/Sources/Settings/*` (a `BeaconsSettingsView` + the `settings-beacons`
  row)
- Create: `App/Sources/Settings/BeaconsSettingsView.swift`

- [ ] **Step 1: Beacon editor arm.** `EditableScheduleKind.beaconTrigger` ("When
  I'm near a beacon"); summary case; drafts (uuid/major/minor/name + shared
  direction/delay/cancel); editor section with UUID field
  (`group-beacon-uuid`), major/minor (`group-beacon-major`/`-minor`), name
  (`group-beacon-name`), direction + delay + cancel controls, a short
  what-is-an-iBeacon footnote linking cheap ESP32/tile options (#60), and the
  Always hint. `draftSchedule` builds `.beaconTrigger(...)` (invalid UUID →
  keep the field, disable Save via the existing questions-empty gate pattern
  extended, or normalize).
- [ ] **Step 2: Beacons settings surface.** `BeaconsSettingsView`: list known
  beacons from beacon groups via `monitorObserver.beacons()` with the live
  in-range indicator (`beacon-in-range`); a `settings-beacons` NavigationLink
  in the appropriate settings section.
- [ ] **Step 3: UI test (deferred to CI).** Under `--mock-sensors` (observer
  authorized, no CLMonitor): create a place group and a beacon group via the
  editor, save, assert the list shows the summaries and NO needs-Always hint.
  DEFER running the full simulator UI suite to CI (per this session's
  constraint — other agents contend for simulators).
- [ ] **Step 4: Wrap.** `swift test` + `xcodebuild build-for-testing` green;
  self-review the diff (no exhaustive-switch `default:`; kit imports no
  CoreLocation — grep; v2 nil-omission proven by test; no entitlement diff;
  replan remove-before-add untouched; `mprompt-` NOT in the removal batch).
  Completion note here. Commit `feat: beacon-trigger prompt groups + Beacons
  settings` → push. Whole-branch review + PR follow.

---

## Completion note

_(appended on ship)_
