# Design: Apple Watch app (Plan 19)

**Status:** design for GitHub issue #7 (the issue tracks the whole watch effort and stays open through implementation). Companion plan: `docs/superpowers/plans/2026-07-10-dispatch-plan-19-watch.md`.

## Goal

File reports from the wrist. Specifically: answer the quick Yes/No question, file a minimal report against any enabled question, see status at a glance (complications), and get prompt notifications on the watch — all without pulling out the phone.

## The architectural question: independent vs phone-tethered

Two viable shapes:

**A. Phone-tethered (WatchConnectivity):** the watch app is a thin client; data lives on the phone; `WCSession` ferries questions over and answers back.

**B. Independent watchOS app with its own CloudKit-synced store:** the watch runs the same DispatchKit + SwiftData + CloudKit-mirroring stack the phone does; the private CloudKit database (`iCloud.io.robbie.Dispatch`) is the sync fabric, exactly as it already is between two iPhones.

### What the App Group does NOT give us — be precise

The App Group store move (plan 14) is why widgets work, and it is tempting to assume the watch gets the same deal. It does not. **App Group containers are per-device: they share data between processes on one device, never across devices.** The watch app runs on the watch with its own filesystem; the phone's `group.io.robbie.Dispatch` container is unreachable from it. This has been true since watchOS 2 moved app code onto the watch — Apple's guidance is explicit that shared-group-container designs "must be redesigned", each device manages "its own copy of any shared data in the local container directory", and cross-device sharing goes through Watch Connectivity or CloudKit ([App Groups on watchOS — Apple Developer Forums, Apple-staff answer](https://forums.developer.apple.com/thread/3927); corroborated in [thread 87428](https://developer.apple.com/forums/thread/87428): "App Groups sharing is not supported since watchOS 2. Use watchConnectivity or cloudKit").

What an App Group on the watch *does* give us: sharing between the watch app and its own embedded WidgetKit extension (complications) — the same pattern as on the phone, one device over.

### Honest weighing

| | A. WatchConnectivity thin client | B. Independent + CloudKit |
|---|---|---|
| Works with phone out of range/off | No (v1 flows dead without a reachable phone) | Yes — this is the entire point of a wrist device |
| New code surface | New WCSession protocol on BOTH targets: message schema, queuing, reachability handling, versioning — a second sync system to maintain forever | Near zero new sync code: SwiftData `cloudKitDatabase: .private` on the watch is the same line the phone already has |
| Reuses existing hardening | No — SyncDedupe, RemoteChangeObserver patterns don't apply to WCSession | Yes — dedupe of same-record collisions between devices is exactly what `SyncDedupe` already does for 2-phone sync (user-verified on hardware 2026-07-09) |
| Latency of a filed answer reaching the phone | Seconds when reachable, indefinite otherwise | CloudKit round-trip (typically seconds-to-minutes); acceptable for a life-logging journal, not a chat app |
| Offline behavior | Must build our own queue | SwiftData mirroring queues locally and pushes when it can — built in |
| Platform support | WatchConnectivity: watchOS 2+ ([Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity)) — but Apple: an independent watch app "can't rely on the Watch Connectivity framework to transfer data or files from a companion iOS app… If you need to sync data between devices, consider using CloudKit" ([Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)) | SwiftData + `ModelConfiguration.CloudKitDatabase`: **watchOS 10.0+** ([SwiftData](https://developer.apple.com/documentation/swiftdata), [ModelConfiguration.CloudKitDatabase](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct)); CloudKit itself watchOS 3+ ([CloudKit](https://developer.apple.com/documentation/cloudkit)). Our floor is watchOS 26 (matches the iOS 26 app floor; watchOS 26 SDK shipped with Xcode 26, and App Store submissions require it from April 2026 — [watchOS 26 Release Notes](https://developer.apple.com/documentation/watchos-release-notes/watchos-26-release-notes)) — far above every requirement |
| Store size on watch | Small | Full store on-wrist. Dispatch stores text answers + numeric sensor readings, no media blobs — a full personal history is small (MBs). Accepted. |

### Decision: **B — independent watchOS app, CloudKit-synced (companion-style, `WKRunsIndependentlyOfCompanionApp`)**

Rationale, compressed: CloudKit sync between devices is a problem this codebase has already solved and hardened (plan 13, SyncDedupe, remote-change pipeline); WatchConnectivity would be a *second, new* sync system that dies when the phone is away — the exact scenario a watch app exists for. Apple's own guidance for independent watch apps names CloudKit as the sync mechanism and disqualifies Watch Connectivity as a primary data source (citation above).

Concretely: a watch app target embedding DispatchKit, opening its own local SwiftData store (in the watch's *own* app-group container, shared with the watch widget extension) with `cloudKitDatabase: .private("iCloud.io.robbie.Dispatch")` mirroring — the same `SyncPolicy` decision logic, the same store, a third device in an already-working mesh. It is a companion app (users have the iPhone app; onboarding, question authoring, settings, visualizations all stay phone-side) but marked independent (`WKRunsIndependentlyOfCompanionApp = YES` — "the app doesn't need its iOS companion app to operate properly", [WKRunsIndependentlyOfCompanionApp](https://developer.apple.com/documentation/BundleResources/Information-Property-List/WKRunsIndependentlyOfCompanionApp)) so filing works with the phone at home. Not watch-only (`WKWatchOnly` is for apps with *no* related iOS app — [WKWatchOnly](https://developer.apple.com/documentation/BundleResources/Information-Property-List/WKWatchOnly)).

WatchConnectivity is NOT part of v1. If sync-freshness nudging ever matters (e.g. "poke the watch to re-fetch after a phone edit"), it can be added later as an optimization, never as the data path.

### Sync-freshness reality (accepted, documented)

CloudKit's background push story on watch is weaker than on the phone: **background notifications sent to iPhone are never forwarded to Apple Watch** ("It never forwards background notifications to Apple Watch; however, with watchOS 6 and later you can also send background notifications directly to Apple Watch" — [Taking advantage of notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)). SwiftData's mirroring on the watch therefore syncs primarily when the app runs (launch/foreground) rather than via silent pushes. For v1 this is accepted: the watch pulls fresh questions when opened, and answers filed on the watch upload opportunistically. Complication staleness is bounded by WidgetKit timeline reloads on watch-app foreground. Anything fancier (direct-to-watch pushes, `WKApplicationRefreshBackgroundTask` scheduling) is deferred until real-world staleness proves annoying.

## v1 scope

1. **Quick answer from the wrist.** The watch home screen leads with the enabled quick Yes/No question (same eligibility logic as `WidgetQuickAnswer` — reuse from DispatchKit). One tap files a minimal report into the watch's local store; mirroring uploads it; the phone's existing remote-change pipeline (dedupe → vocabulary → Spotlight → replan) ingests it like any other device's report. The phone-side pending-action marker trick the widget uses (nag cancellation via app-group defaults) does NOT carry over — the watch cannot reach the phone's defaults. Instead: nag/`lastActedAt` reconciliation happens phone-side when the report arrives via sync (the remote-change pipeline already replans notifications on remote report arrival — verify and extend if the report-arrival → nag-cancel link is missing).
2. **Minimal report filing.** A question list (enabled questions, prompt-group order) with per-type minimal inputs: yes/no buttons, choice list, number (digit crown-friendly stepper), text via dictation/scribble (system keyboard input). No sensors, no drafts, no editing — file-and-done. Sensor context (location, weather, health) is explicitly NOT captured watch-side in v1; reports filed from the watch carry answers only.
3. **Complications via WidgetKit accessory widgets.** A watch widget extension rendering the existing `WidgetSnapshot` (streak, today count, next prompt) in `accessoryCircular`/`accessoryRectangular`/`accessoryInline` (all watchOS 9+ — [WidgetFamily.accessoryRectangular](https://developer.apple.com/documentation/widgetkit/widgetfamily/accessoryrectangular)) plus `accessoryCorner` (watchOS-only, watchOS 9+ — [WidgetFamily.accessoryCorner](https://developer.apple.com/documentation/widgetkit/widgetfamily/accessorycorner)). The snapshot math is already pure DispatchKit code; the watch widget reads the watch's shared store read-only, exactly mirroring the phone widget's architecture. Note the phone widget's accessory families already exist — the watch extension is a new target reusing the same views where SwiftUI allows.
4. **Wrist prompt notifications.** Nothing to build for the baseline: the iPhone app's *local* notifications (all prompt scheduling is local) forward automatically — "Local / iOS app / Apple Watch or iPhone, depending on the locked/unlocked state of both devices" ([Taking advantage of notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)). The forwarding decision rules (phone unlocked+screen on → phone; else watch on wrist+unlocked → watch; else phone) are the system's, not ours. Mirrored notifications surface the category's action buttons in the long-look interface ("The bottom contains a Dismiss button and any registered action buttons" — [Presenting notifications on Apple Watch](https://developer.apple.com/documentation/watchos-apps/presenting-notifications-on-apple-watch)). **Decision: v1 does NOT schedule watch-local notifications.** Watch-side scheduling would duplicate prompts (watch-local notifications are watch-only and don't participate in cross-device dedup with the phone's local ones — the forwarding table has no dedup row for two *local* schedulers; only remote pushes sent to both devices get "best destination" dedup, [Enabling and receiving notifications](https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications)). The watch app handles a tapped forwarded notification by deep-linking to the matching question when the action identifier arrives via its `UNUserNotificationCenterDelegate` — but scheduling authority stays 100% phone-side in v1.

## Explicitly deferred (not v1)

- **Watch-local prompt scheduling** (for phone-free prompting) — needs a scheduling-authority handoff design to avoid double prompts; revisit only if users actually run phone-free for long stretches.
- **Sensor context on watch reports** (HealthKit is on watchOS — [HealthKit](https://developer.apple.com/documentation/healthkit) — but capture parity is a project of its own).
- **WatchConnectivity freshness nudges**, direct-to-watch background pushes, background refresh tasks.
- **Visualizations/insights/digest/search on watch**, question authoring/editing, settings beyond a sync-status line, backups (phone-only), Focus filters watch-side, catalog browsing, complications with user-configurable content (intent configuration).
- **State of Mind logging from the watch.**

## Entitlement / profile / pipeline impact (the expensive part)

New targets in `project.yml`:
- `DispatchWatch` — `type: application`, `platform: watchOS`, deployment target watchOS 26, bundle ID `io.robbie.Dispatch.watchkitapp`, Info.plist keys `WKApplication = YES`, `WKCompanionAppBundleIdentifier = io.robbie.Dispatch` ([WKCompanionAppBundleIdentifier](https://developer.apple.com/documentation/BundleResources/Information-Property-List/WKCompanionAppBundleIdentifier): "The value should be the same as the iOS app's CFBundleIdentifier"), `WKRunsIndependentlyOfCompanionApp = YES`. Depends on package DispatchKit. Embedded by `DispatchApp`.
- `DispatchWatchWidgets` — `type: app-extension` (WidgetKit), `platform: watchOS`, bundle ID `io.robbie.Dispatch.watchkitapp.widgets`, embedded in the watch app.
- Both carry `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` matching the iOS targets (established archive-validation constraint).
- `Package.swift`: DispatchKit `platforms` gains `.watchOS(.v26)` (kit imports are Foundation/SwiftData/os/Observation/CryptoKit/SwiftUI — all watchOS-available; any stragglers get `#if canImport` treatment).

Entitlements (two new files):
- Watch app: `com.apple.security.application-groups` = [`group.io.robbie.Dispatch`] (watch-local sharing with its widget extension — same group ID string is fine; it names a *watch-side* container), iCloud services CloudKit + container `iCloud.io.robbie.Dispatch`, `aps-environment` (delegate registration for CloudKit subscriptions; harmless if unused in v1).
- Watch widgets: app group only (mirror of the phone widget entitlements).
- NO HealthKit/WeatherKit/time-sensitive on watch targets in v1.

Provisioning (the pinned-profiles reality): the pipeline exports with **manual signing** against two pinned App Store profiles (`scripts/ExportOptionsUpload.plist`: `Dispatch App Store`, `Dispatch Widgets App Store`). Two new bundle IDs mean **two new ASC bundle-ID registrations + two new App Store profiles**, created via the ASC API — the exact curl recipe from 2026-07-08 is in the session ledger (referenced by plan 25: `POST /v1/profiles` with the current local Apple Distribution cert; existing bundle-ID resources 2532PZDYH6/VYY3Q8UZPQ show the pattern). `ExportOptionsUpload.plist` gains two `provisioningProfiles` entries. The archive step (`upload-testflight.sh`) uses cloud-managed automatic signing for the archive itself and needs no change beyond the scheme building the watch targets; the export step is where the new profiles bite. Capability enablement (App Groups, iCloud) must be set on the new bundle-ID resources BEFORE profile creation or the profiles won't carry the entitlements — same archive-prove-then-commit discipline as plan 25.

App Store Connect: the watch app rides the existing app record (companion apps are one submission); TestFlight builds carry it automatically once the archive contains it.

## Testing

- Kit tests: unchanged suite must pass with the watchOS platform added (the kit is the shared brain; no watch-specific kit logic expected in v1 beyond what quick-answer eligibility already has).
- Watch UI: minimal smoke via simulator boot + a `--ui-testing`-style test-gated local store (the established injected-directory pattern; ubiquity/CloudKit never touched under test args).
- The genuinely sim-unverifiable parts — real CloudKit sync watch↔phone, notification forwarding behavior, complication refresh — go on the user device script, per project convention.

## Error handling

Watch store construction follows the phone's never-fail-launch pattern (CloudKit construction failure → local-only fallback + logged). No shared-container assumptions between devices anywhere in code or copy. Quick answer on the watch re-fetches the question by ID before filing (stale-timeline rule, same as `QuickAnswerIntent`).

## Constraints inherited from the project

Suites green per commit; additive schema only (no model changes in this plan at all); test-gating absolute; accessibility per the plan-17 bar on new watch UI; SyncDedupe determinism untouched; build numbers move in both existing targets AND both new targets together.
