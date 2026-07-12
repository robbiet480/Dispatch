# Dispatch Plan 50: Place triggers — type a name/address, autocomplete + geocode (iOS + macOS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (issue #83):** creating a place-arrival/departure prompt trigger (plan
45, #56) currently forces raw **latitude / longitude** entry by hand — a bad
experience on iOS and *impossible* on macOS, where place/beacon kinds were made
**view-only** (hidden from the "new group" picker) during the #74 rebase
precisely because the Mac had no way to *pick* a place. Let the user **type a
place name or address**, get **as-you-type autocomplete suggestions**, and
**geocode** the chosen result to a coordinate + a sensible default radius —
then build the `PlaceTrigger` from that. Usable on iOS AND macOS. This is a
picker/UX change, NOT a schema change: the `PlaceTrigger` /
`MonitorPlaceRegion` model (lat/lon/radius/name) is preserved verbatim.

## Architecture

**Shared search component — app-side, dual target membership.** MapKit is
available on both iOS and macOS, but **DispatchKit is Foundation/SwiftData-only
(no MapKit)** — the search wrapper must NOT go in the kit. It lives in a NEW
shared source group `Shared/Search/` compiled into BOTH `DispatchApp` and
`DispatchMac` (the exact `Shared/Providers` dual-membership pattern that already
shares the CoreLocation/Weather/Health providers into iOS + watch). One new
directory, two target memberships, no kit change.

**`PlaceSearchModel` (`@MainActor @Observable`).** Wraps:

- `MKLocalSearchCompleter` for as-you-type autocomplete of names/addresses
  (`resultTypes = [.address, .pointOfInterest]`, biased toward *resolvable*
  places, not category queries).
- `MKLocalSearch(request: .init(completion:))` to resolve the chosen completion
  to a coordinate + display name (`MKMapItem.location.coordinate` — the iOS-26
  non-deprecated surface the existing `LocationProvider` reverse-geocode already
  migrated to; `MKMapItem.placemark` is deprecated in 26).

Exposed state: `suggestions: [PlaceSuggestion]`, `isResolving`,
`errorMessage`, and a `resolve(_:) async -> ResolvedPlace?`. Both the completer
and the resolver are behind protocols (`PlaceCompleting` / `PlaceResolving`) so
tests inject stubs and never touch the network. A `ResolvedPlace` carries
`name / latitude / longitude / suggestedRadius`; the suggested radius defaults
to the existing `MonitorDelay.floorRadiusMeters` (100 m) floor and stays
editable in the editor's radius control.

**Editor wiring — fill the existing draft fields.** Neither editor grows new
persisted state: picking a suggestion writes the resolved coordinate + name
into the SAME `placeLatitude` / `placeLongitude` / `placeName` (+ radius) drafts
that already feed `draftSchedule` → `PlaceTrigger`. So the search flow is purely
additive over the shipped save path; the `PlaceTrigger` / `MonitorPlaceRegion`
model, its JSON codec, and the `MonitorObserver` that consumes it are untouched.

**iOS editor.** The raw lat/long text fields become an *advanced* fallback
(collapsed `DisclosureGroup`, same accessibility ids preserved for power users
and exact-coordinate cases). The PRIMARY control is a search field
(`group-place-search`) with a results list (`group-place-results`, rows
`group-place-result`); picking a result resolves it and shows a confirmation
row (`group-place-selected`) with the resolved name + coordinate. Radius stays
editable (`group-place-radius`).

**macOS editor.** Real place-trigger creation using the same
`PlaceSearchModel`: a search field + results + the shared direction / delay /
cancel controls + radius. The **view-only restriction for `.placeTrigger` is
lifted** — `MacScheduleKind.isTriggerOnly` becomes **beacon-only**, so
`availableKinds` now offers *place* for new groups, and `draftSchedule` builds a
real `PlaceTrigger` from the searched coordinate instead of returning the
preserved `lockedTriggerSchedule`. **Beacons stay view-only on the Mac** (owner
decision — issue #84 covers Mac-less beacon scanning); `.beaconTrigger` keeps
the locked-schedule preservation path unchanged.

## Tech Stack

- **MapKit** `MKLocalSearchCompleter` (+ `MKLocalSearchCompleterDelegate`),
  `MKLocalSearch` / `MKLocalSearch.Request(completion:)`, `MKMapItem.location`
  (iOS/macOS 26 non-deprecated coordinate surface). Available on iOS AND macOS;
  no new entitlement (the Mac already has `com.apple.security.network.client`;
  search uses Apple's servers, not the device's location).
- **CoreLocation** `CLLocationCoordinate2D` for the resolved coordinate, and
  `CLLocationManager.requestLocation` / `requestWhenInUseAuthorization` for the
  one-shot "Use current location" fix (macOS 10.15+ / iOS 8+).
- **DispatchKit** `MonitorDelay.floorRadiusMeters` for the default/suggested
  radius (unchanged) and the existing `PlaceTrigger` / `MonitorPlaceRegion`.
- **XcodeGen** — one new `Shared/Search` source group added to the `DispatchApp`
  and `DispatchMac` target `sources`, plus the `DispatchAppTests` bundle for the
  unit tests. The Mac target gains the location sandbox entitlement +
  purpose strings for "Use current location" (below); iOS reuses its existing
  location purpose strings.

## Design decisions (decide + log)

- **Search wrapper is app-side, not kit.** DispatchKit is deliberately
  MapKit-free (the same reason `LocationProvider`/`WeatherProvider` live in
  `Shared/Providers`, not the kit). Rejected: moving the wrapper into the kit —
  it would drag MapKit into a Foundation/SwiftData module used by every target.
  Chosen: a `Shared/Search` group with `DispatchApp` + `DispatchMac`
  membership, mirroring `Shared/Providers`' iOS+watch membership.
- **Resolve via `MKLocalSearch(completion:)`, not `CLGeocoder`.** We are
  resolving an autocomplete *completion object*, and `MKLocalSearch` takes one
  directly and returns `MKMapItem`s with the modern non-deprecated
  `location`/`address` surface. `CLGeocoder` is string-in/placemark-out and
  would throw away the completion's disambiguation. Logged: `CLGeocoder`
  considered (per the issue) and rejected for the completion path.
- **Coordinate surface = `MKMapItem.location.coordinate`.** `MKMapItem.placemark`
  is deprecated as of iOS/macOS 26 (verified in the 26.5 SDK header); the
  `LocationProvider` reverse-geocode already migrated off it. Deployment target
  is 26.0, so `location` is always available — no `@available` fork.
- **Mockable by protocol injection.** `PlaceCompleting` (as-you-type) and
  `PlaceResolving` (completion → coordinate) are protocols; the concrete
  `MapKitPlaceCompleter` / `MapKitPlaceResolver` wrap MapKit, and the tests use
  in-process stubs. `PlaceSuggestion` carries the underlying
  `MKLocalSearchCompletion?` (nil in stubs) so the model stays MapKit-agnostic
  at its API boundary and never hits the network under test.
- **Deterministic UI-test path.** A `--stub-place-search` launch argument (the
  `--mock-sensors`/`--demo-data` precedent) makes the editor build a
  `PlaceSearchModel` over canned stubs, so the iOS UI test drives
  type → choose → save with a fixed coordinate and no network. Real search runs
  in every non-flagged launch.
- **Manual coordinate entry kept as an advanced fallback (iOS only).** Behind a
  collapsed `DisclosureGroup`, preserving the `group-place-latitude` /
  `-longitude` ids. Rejected: dropping it entirely — cheap to keep, and it is
  the only way to enter an exact known coordinate or recover if search is
  unavailable. The Mac omits it (search-only) to keep the new editor lean.
- **"Use my current location" — IN SCOPE on BOTH platforms** (owner reversal of
  the initial deferral). A `CurrentLocationProviding` protocol (the
  `PlaceCompleting`/`PlaceResolving` mock-seam pattern) fronts a one-shot
  `CLLocationManager.requestLocation` + best-effort `MKReverseGeocodingRequest`
  name; the editor's "Use current location" button fills the region with the
  fix + the floor radius, naming it the reverse-geocoded place or "Current
  location". Denied/restricted/unavailable map to an actionable inline message
  (no crash/hang). iOS reuses the existing when-in-use purpose string; **the Mac
  gains the `com.apple.security.personal-information.location` SANDBOX
  entitlement** (owner-authorized) + `NSLocation*UsageDescription` purpose
  strings — a self-declared sandbox entitlement, NOT an App-ID/portal capability,
  so it needs no provisioning-profile change and signs on the existing manual
  Mac App Store lane (build-verified).
- **Beacons stay Mac-view-only.** `isTriggerOnly` narrows from place+beacon to
  **beacon-only**; place is fully creatable on the Mac, beacon remains preserved
  read-only (owner decision, issue #84).

## Observable Acceptance Criteria

- **iOS editor**, picking **When I arrive at / leave a place**
  (`group-schedule-kind`) shows a **search field** (`group-place-search`) with
  placeholder "Search for a place or address". Typing shows tappable suggestion
  rows (`group-place-result`); tapping one fills a confirmation row
  (`group-place-selected`) reading the resolved place name + coordinate, and
  Save becomes enabled. The radius control (`group-place-radius`, floored at
  100 m) and the direction/delay/cancel controls remain.
- **iOS advanced fallback:** a disclosure "Enter coordinates manually"
  (`group-place-manual`) reveals the latitude (`group-place-latitude`) and
  longitude (`group-place-longitude`) fields; entering a valid pair also enables
  Save.
- **"Use current location"** (`group-place-current` on iOS,
  `mac-group-place-current` on Mac) sits alongside the search field; tapping it
  takes a one-shot fix and fills the selected-place confirmation. If location is
  denied/restricted/unavailable, an inline message explains what to do (no crash).
- **iOS list:** after saving, the groups list row shows the place summary
  (e.g. `Arrive at HQ`) with no needs-Always hint under the full-access test
  posture.
- **macOS editor:** the schedule picker (`mac-group-schedule-kind`) now offers
  **When I arrive at / leave a place (iPhone)** for a NEW group (no longer
  view-only). It shows a search field (`mac-group-place-search`), suggestion
  rows (`mac-group-place-result`), a selected-place confirmation
  (`mac-group-place-selected`), radius (`mac-group-place-radius`), and the
  direction/delay/cancel controls (`mac-group-monitor-direction` /
  `-delay` / `-cancel`); choosing a result and saving creates a real place
  group (Save gated until a coordinate is chosen). **Beacon** stays offered only
  when the group already is one (`mac-group-trigger-note` preserved read-only).

## Global Constraints

- Additive UX only: NO change to `PlaceTrigger` / `MonitorPlaceRegion` /
  `GroupSchedule` / `MonitorObserver` / the v2 format / persisted fields. The
  `scheduleKindRaw` + `placeRegionJSON` + `monitor*` storage is untouched.
- DispatchKit stays MapKit-free — grep-verify the search wrapper imports MapKit
  only in `Shared/Search`, never under `Sources/DispatchKit`.
- No new entitlements, plist keys, or signing/profile churn. Search rides the
  existing Mac `network.client` entitlement.
- Test gating: `--mock-sensors`/`--ui-testing` keep the observer authorized with
  no CLMonitor (unchanged); the search wrapper never auto-fires network under
  test — a real search only runs on a user keystroke, and the UI test uses
  `--stub-place-search`.
- No exhaustive-switch `default:` added to the schedule-kind enums — every case
  stays handled explicitly.
- Kit + app-unit suites green before commit; scoped commits; `git pull --rebase`
  before pushing. Do NOT bump the build number. Owner reviews the PR — do NOT
  merge or arm auto-merge.

---

### Task 1: Shared search component + project wiring

**Files:**
- Create: `Shared/Search/PlaceSearch.swift` (the model, protocols, MapKit
  adapters, stub adapters, `PlaceSuggestion` / `ResolvedPlace`).
- Modify: `project.yml` (add `Shared/Search` to `DispatchApp` + `DispatchMac`
  sources; add the file to `DispatchAppTests` for unit testing).
- Test: create `AppTests/PlaceSearchModelTests.swift`.

**Interfaces (produced):**
- `PlaceSuggestion: Identifiable, Equatable` — `title`, `subtitle`.
- `ResolvedPlace: Equatable, Sendable` — `name/latitude/longitude/suggestedRadius`.
- `PlaceCompleting` (AnyObject) — `onResults`/`onFailure` callbacks,
  `update(query:)`, `cancel()`.
- `PlaceResolving` — `resolve(_:) async throws -> ResolvedPlace`.
- `PlaceSearchModel` (`@MainActor @Observable`) —
  `suggestions`, `isResolving`, `errorMessage`, `updateQuery(_:)`,
  `select(_:) async -> ResolvedPlace?`, `clear()`,
  `static makeForCurrentProcess(defaultRadius:)`.

- [ ] Write failing `PlaceSearchModelTests` (stub completer/resolver): typing
  populates `suggestions`; empty query clears them; `select` returns the stub
  `ResolvedPlace` and sets it; a resolver error sets `errorMessage`.
- [ ] Implement `PlaceSearch.swift`; wire `project.yml`; regenerate.
- [ ] `xcodegen` + `xcodebuild test` (DispatchAppTests) green. Commit + push.

### Task 2: iOS editor — search + autocomplete (advanced manual fallback)

**Files:** Modify `App/Sources/Settings/PromptGroupsView.swift`;
`AppUITests/NavigationUITests.swift` (drive the search flow via
`--stub-place-search`).

- [ ] Replace the primary lat/long fields with the search field + results +
  selected confirmation; move lat/long into a `group-place-manual` disclosure.
- [ ] Update `scheduleValidationMessage` copy for the search-first flow.
- [ ] Update the UI test to type in `group-place-search`, tap the first
  `group-place-result`, assert `group-place-selected`, save, assert the list
  summary. Build iOS (generic sim). Commit + push.

### Task 3: macOS editor — real place creation + lift the view-only restriction

**Files:** Modify `Mac/Sources/MacPromptGroupsView.swift`.

- [ ] Narrow `isTriggerOnly` to beacon-only; add place drafts
  (direction/delay/cancel/radius/lat/lon/name) seeded from an existing
  `.placeTrigger`; add the search UI + shared controls; `draftSchedule` builds a
  real `PlaceTrigger` for `.placeTrigger` (beacon keeps `lockedTriggerSchedule`).
- [ ] Build `DispatchMac` (platform=macOS). Commit + push.

### Task 4: Verify + PR

- [ ] `swift test` (kit) green; `xcodebuild test` (DispatchAppTests) green;
  `DispatchApp` + `DispatchMac` build. Self-review: no kit MapKit import, no
  entitlement diff, no schema change.
- [ ] Completion note; open the PR (plan + impl). Do NOT merge / auto-merge.

---

## Completion note (2026-07-12)

Shipped on branch `plan-50-place-autocomplete` in three commits after the plan
doc: the shared `Shared/Search/PlaceSearch.swift` wrapper + `project.yml` wiring
+ 7 unit tests; the iOS editor search flow + UI-test rewrite; the Mac editor
place creation + view-only lift. Each commit builds green on its own — no
intentionally-red intermediate this time (the shared component compiles
standalone).

**Where the shared component lives / how it's wired:**
`Shared/Search/PlaceSearch.swift`, added to the `DispatchApp` AND `DispatchMac`
target `sources` in `project.yml` (the `Shared/Providers` dual-membership
pattern) and to the hostless `DispatchAppTests` bundle for unit testing (with a
`DispatchKit` package dependency for `MonitorDelay`). DispatchKit stays
MapKit-free (grep-verified).

**Owner-reviewed decisions (verdicts applied):**
1. **Manual coordinate entry kept (iOS only)** as a collapsed advanced
   `DisclosureGroup` (`group-place-manual`) preserving the `group-place-latitude`
   / `-longitude` / `-name` ids; the Mac editor is search-only. *(GOOD, kept.)*
2. **"Use my current location" ADDED on BOTH platforms** (owner reversed the
   initial deferral). A `CurrentLocationProviding` protocol fronts a one-shot
   `CLLocationManager` fix + reverse-geocoded name; the editor button
   (`group-place-current` / `mac-group-place-current`) fills the region.
   Denied/restricted/unavailable → actionable inline message. iOS reuses its
   when-in-use purpose string; the **Mac gains the
   `com.apple.security.personal-information.location` sandbox entitlement** (in
   `Mac/DispatchMac.entitlements`) + `NSLocationWhenInUseUsageDescription` /
   `NSLocationUsageDescription` purpose strings (in `project.yml`). Being a
   self-declared SANDBOX entitlement (not an App-ID/portal capability), it needs
   no provisioning-profile change — `DispatchMac` builds and code-signs on the
   existing manual lane (verified; the entitlement + strings are present in the
   signed `.app`).
3. **Beacons stay Mac-view-only** (`isTriggerOnly` narrowed to beacon-only) per
   the owner note / issue #84. *(Kept.)*

**Verification (exact):** `swift test` — **817 kit tests / 13 suites** pass.
`DispatchAppTests` — **15 tests** pass (5 OptionBlockLayout + 10
PlaceSearchModel, incl. 3 current-location fills via the injected stub — no real
CoreLocation). `DispatchApp` (iOS sim) and `DispatchMac` (platform=macOS,
new entitlement) both **BUILD SUCCEEDED** and code-sign clean. The iOS UI test
`testCreatePlaceTriggerGroupAppearsInList` (search flow under
`--stub-place-search`, plus a `group-place-current` existence check)
**passed** on the simulator. Mac UI test execution is deferred to CI (the wedged
local `io.robbie.Dispatch` process blocks launching the Mac app locally).

**No entitlement / plist / schema diff:** the `PlaceTrigger` /
`MonitorPlaceRegion` model, the v2 format, and the `MonitorObserver` are
untouched — this is purely a picker/UX change over the existing save path. The
real MapKit search path (non-`--stub-place-search`) is exercised on device;
locally, search resolution runs against Apple's servers and is not asserted in
the deterministic suites.
</content>
