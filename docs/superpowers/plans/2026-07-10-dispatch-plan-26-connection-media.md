# Dispatch Plan 26: Connection granularity + media capture

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** two sensor upgrades — (A) the connection sensor learns wired/satellite and cellular generations (5G/LTE/3G/2G) instead of the coarse cellular/wifi/none triad, and (B) a new media sensor records what's audibly playing at report time (Apple Music → Spotify → other-audio floor).

**Architecture:** (A) additive `ConnectionType` raw ints (existing 0/1/2 NEVER renumbered) with a kit-side pure radio-technology mapping; detection stays app-side in `ConnectionProvider` (NWPath interface types + CoreTelephony generation + iOS 26 ultra-constrained satellite check). (B) a kit `MediaSample` value + `SensorKind.media` riding the existing provider/coordinator/toggle/export machinery; the provider chain DEGRADES THROUGH its levels (never bails to nil early) via a pure kit `MediaChain`; Spotify App Remote is an app-side reader behind a protocol so everything above it is testable without the SDK.

**Tech Stack:** Network.framework (NWPath), CoreTelephony (CTTelephonyNetworkInfo), MediaPlayer (MPMusicPlayerController, MPMediaLibrary), AVFAudio (AVAudioSession), Spotify iOS SDK (App Remote — SpotifyiOS.xcframework), SwiftData additive fields, Keychain (SecItem).

## Design decisions (decide + log)

- **Connection taxonomy (additive raw ints, existing values frozen):** `wired = 3`, `cellular5G = 4`, `cellularLTE = 5`, `cellular3G = 6`, `cellular2G = 7`, `satellite = 8`. `cellular = 0` survives as the plain fallback (simulator, no SIM, unknown radio). Old reports keep their coarse values forever — no migration, no reinterpretation.
- **displayName strings (exact):** None, Wi-Fi, Wired, 5G, LTE, 3G, 2G, Cellular, Satellite. Lives on the kit enum so detail view, capture checklist, and CSV share one mapping.
- **Detection order:** satisfied path → wifi → wired (wiredEthernet) → cellular. Within cellular: satellite when `path.isUltraConstrained` (iOS 26 API — **verify the exact property name against the SDK during implementation**; deployment target is already iOS 26.0 so no `#available` gate should be needed once the name is confirmed — if the property doesn't exist in the SDK under any name, fall back to the plain generation mapping and log the finding). Otherwise cellular generation via `CTTelephonyNetworkInfo`, using `dataServiceIdentifier` to pick the active data SIM's entry in `serviceCurrentRadioAccessTechnology`; nil/unknown → plain `.cellular`.
- **Radio mapping is a kit pure function on strings** (`ConnectionType.cellular(fromRadioAccessTechnology:)`) so DispatchKit stays free of CoreTelephony and the table is unit-testable. The `CTRadioAccessTechnology*` constants' runtime values equal their names (verify once at implementation with a debug print); the provider passes the dictionary value straight through.
- **v2 stays lenient by construction:** `connection` is a raw `Int?` end-to-end (model, DTO, importer) and `Report.connectionType` already returns nil for unknown raws (`RawValueFallbackTests` proves it with 99). No importer change needed — new ints just start resolving; genuinely unknown ints still import, persist, and re-export untouched.
- **CSV gains a `connection` column** APPENDED to the END of `sensorColumns` (after `photoCount`, before question prompts) so existing consumers' column prefix is stable. Value = `displayName`, empty when nil/unknown.
- **Viz: no connection usage exists** in `Sources/DispatchKit/Visualization/` (verified by grep 2026-07-10) — display sites are ReportDetailView, CaptureChecklistView, SensorFailureHint labels, and the new CSV column. Re-grep at implementation.
- **MediaSample stores raw values for leniency** (the connection precedent): `source` is a raw String on the wire (`CodingKeys` keep the JSON keys clean), `playbackState` a raw Int; typed accessors return nil/optional for unknowns so a future source never breaks import.
- **Provider chain degrades through its levels, never bails (Robbie 2026-07-10):** (1) Apple Music sample when MPMediaLibrary is authorized AND systemMusicPlayer is playing with a nowPlayingItem; (2) else Spotify App Remote read when the user has connected Spotify — connect-read-disconnect inside the capture core's timeout/partial-result semantics, ANY failure or budget overrun yields nil and FALLS THROUGH; (3) else `AVAudioSession.sharedInstance().isOtherAudioPlaying` (synchronous, free) as the boolean floor → `MediaSample(source: .otherAudio, playing)`. **nil media = nothing audible** — when `isOtherAudioPlaying` is false the provider emits no sample (payloads stay lean; documented here and in code). Provider-side this surfaces as `.unavailable(reason: "Nothing playing")`, so `report.media` stays nil and the checklist hint reads honestly.
- **Spotify claims are unverified until implementation.** Every Spotify statement in this plan (API names — `SPTAppRemote`, `authorizeAndPlayURI`, `authorizationParameters(from:)`, `playerAPI.getPlayerState` — connection lifecycle, token behavior, SDK packaging) MUST be verified against https://developer.spotify.com/documentation/ios during implementation. Task 5 opens with an explicit SDK-distribution verification step.
- **Spotify config + secrets:** client ID and redirect URI are read from `App/Info.plist` keys (`SpotifyClientID`, `SpotifyRedirectURI`) — config, not code constants. The access token is a credential → Keychain (new small `SpotifyTokenStore`, generic-password item; grep-verified there is no existing Keychain helper to reuse). Nothing Spotify-related syncs.
- **Settings placement:** the media sensor toggles like every sensor in Settings → Sensors; `SensorSettingsView` gains a MEDIA section beneath the toggles with the Spotify connection status + a NavigationLink to the new `SpotifySettingsView` (connect/disconnect live there).
- **Quick-answer paths are unaffected:** `QuickAnswerFiler` does NO sensor capture by contract (notification actions + widget intents), so the media provider only ever runs in the app process via `SurveyController.providers(since:)` — no extension-process MediaPlayer/App Remote concerns. Phone-only in v1 (no watch).
- **Media permission is NOT an entitlement:** `NSAppleMusicUsageDescription` purpose string (project.yml `INFOPLIST_KEY_*`) + `MPMediaLibrary.requestAuthorization` joining the onboarding permission cascade as its own sequenced step, with an upgrade top-up for installs that finished onboarding before the step existed (the motion/medications pattern in `PermissionCascade`, including flag-written-BEFORE-steps crash tolerance).

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate).
- Additive v2 format only: new fields optional and omitted when nil; unknown enum raws imported leniently (raw-storage pattern, never a throwing enum decode); NO schemaVersion bump; NEVER renumber existing `ConnectionType` raws 0/1/2.
- No new entitlements — `NSAppleMusicUsageDescription` and all Spotify keys (`LSApplicationQueriesSchemes`, URL scheme, config keys) are plist-only.
- Test gating absolute: `--mock-sensors`/`--ui-testing` → no MediaPlayer/CoreTelephony/AVAudioSession/Spotify calls, no permission dialogs (the PermissionCascade/MockProviders gates already exist — join them).
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.
- Every uncertain platform/SDK claim is verified during implementation and the finding recorded in a code comment: `isUltraConstrained` exact name, `CTRadioAccessTechnology*` constant values, MPMusicPlayerController threading requirements, and ALL Spotify SDK claims (cite https://developer.spotify.com/documentation/ios).

---

### Task 1: Kit — ConnectionType taxonomy, radio mapping, displayName, CSV column

**Files:**
- Modify: `Sources/DispatchKit/Models/Values.swift` (ConnectionType), `Sources/DispatchKit/Export/CSVExporter.swift`
- Test: extend `Tests/DispatchKitTests/RawValueFallbackTests.swift`, `Tests/DispatchKitTests/CSVExportTests.swift`, `Tests/DispatchKitTests/V2ExportTests.swift`; create `Tests/DispatchKitTests/ConnectionTypeTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `ConnectionType` new cases `wired = 3, cellular5G = 4, cellularLTE = 5, cellular3G = 6, cellular2G = 7, satellite = 8` (existing `cellular = 0, wifi = 1, none = 2` untouched)
- `ConnectionType.displayName: String`
- `ConnectionType.cellular(fromRadioAccessTechnology: String?) -> ConnectionType`

- [ ] **Step 1: Write the failing tests** — `ConnectionTypeTests.swift`: (a) raw-value freeze test asserting ALL NINE raws literally (`#expect(ConnectionType.cellular.rawValue == 0)` … `#expect(ConnectionType.satellite.rawValue == 8)`) so any renumbering breaks loudly; (b) displayName table test for all nine exact strings; (c) radio mapping: `"CTRadioAccessTechnologyNR"`/`"CTRadioAccessTechnologyNRNSA"` → `.cellular5G`, `"CTRadioAccessTechnologyLTE"` → `.cellularLTE`, each of WCDMA/HSDPA/HSUPA/CDMAEVDORev0/RevA/RevB/eHRPD → `.cellular3G`, each of Edge/GPRS/CDMA1x → `.cellular2G`, `nil` → `.cellular`, `"garbage"` → `.cellular`. Extend `RawValueFallbackTests`: `connection = 8` → `.satellite`, `connection = 99` still nil (existing assertion untouched). Extend `V2ExportTests`: a report with `connection = 5` round-trips; a report with unknown `connection = 99` exports/imports the raw untouched. Extend `CSVExportTests`: report with `connection = 4` renders "5G" in the new trailing `connection` sensor column; nil connection renders empty.
- [ ] **Step 2: Run `swift test` — expect the new tests FAIL** (cases/members don't exist yet; CSV column missing).
- [ ] **Step 3: Implement.** Replace the enum in `Values.swift`:

```swift
/// Raw values 0–2 match the original Reporter export (gist.github.com/dbreunig/9315705).
/// 3+ are additive (plan 26) — NEVER renumber existing cases; old reports keep coarse values.
public enum ConnectionType: Int, Codable, Sendable, CaseIterable {
    case cellular = 0
    case wifi = 1
    case none = 2
    case wired = 3
    case cellular5G = 4
    case cellularLTE = 5
    case cellular3G = 6
    case cellular2G = 7
    case satellite = 8

    public var displayName: String {
        switch self {
        case .none: "None"
        case .wifi: "Wi-Fi"
        case .wired: "Wired"
        case .cellular5G: "5G"
        case .cellularLTE: "LTE"
        case .cellular3G: "3G"
        case .cellular2G: "2G"
        case .cellular: "Cellular"
        case .satellite: "Satellite"
        }
    }

    /// Maps a CTRadioAccessTechnology* constant VALUE to a cellular generation.
    /// Pure string table so DispatchKit stays CoreTelephony-free; the provider
    /// passes serviceCurrentRadioAccessTechnology's value straight through.
    /// (The constants' runtime values equal their names — verified at implementation.)
    public static func cellular(fromRadioAccessTechnology technology: String?) -> ConnectionType {
        switch technology {
        case "CTRadioAccessTechnologyNR", "CTRadioAccessTechnologyNRNSA":
            .cellular5G
        case "CTRadioAccessTechnologyLTE":
            .cellularLTE
        case "CTRadioAccessTechnologyWCDMA", "CTRadioAccessTechnologyHSDPA",
             "CTRadioAccessTechnologyHSUPA", "CTRadioAccessTechnologyCDMAEVDORev0",
             "CTRadioAccessTechnologyCDMAEVDORevA", "CTRadioAccessTechnologyCDMAEVDORevB",
             "CTRadioAccessTechnologyeHRPD":
            .cellular3G
        case "CTRadioAccessTechnologyEdge", "CTRadioAccessTechnologyGPRS",
             "CTRadioAccessTechnologyCDMA1x":
            .cellular2G
        default:
            .cellular
        }
    }
}
```

CSV: append `"connection"` as the LAST entry of `CSVExporter.sensorColumns` and, in the matching position in the `fields` array, `report.connectionType?.displayName ?? ""`.
- [ ] **Step 4: Run `swift test` — expect PASS** (whole kit suite, not just the new files).
- [ ] **Step 5: Commit** — `git add` the four test files + two source files; `git commit -m "feat(kit): fine-grained connection taxonomy + displayName + CSV column"` → push.

### Task 2: App — connection detection (wired / satellite / cellular generation) + display via kit

**Files:**
- Modify: `App/Sources/Providers/ConnectionProvider.swift`, `App/Sources/Reports/ReportDetailView.swift` (lines ~104–112), `App/Sources/Survey/CaptureChecklistView.swift` (captured-case rendering)

**Interfaces:** Consumes Task 1's `ConnectionType.displayName` and `.cellular(fromRadioAccessTechnology:)`. Produces nothing new kit-side.

- [ ] **Step 1: Rework `ConnectionProvider.capture()`** — keep the existing NWPathMonitor one-shot continuation exactly as-is; replace only the classification tail:

```swift
guard path.status == .satisfied else { return .connection(ConnectionType.none.rawValue) }
return .connection(Self.classify(path).rawValue)
```

with a new `static func classify(_ path: NWPath) -> ConnectionType`:

```swift
static func classify(_ path: NWPath) -> ConnectionType {
    if path.usesInterfaceType(.wifi) { return .wifi }
    if path.usesInterfaceType(.wiredEthernet) { return .wired }
    guard path.usesInterfaceType(.cellular) else { return .cellular } // pre-plan-26 fallback preserved
    // Satellite: iOS 26 ultra-constrained path signal. VERIFY the exact
    // property name against the SDK (design decision above); if absent,
    // delete this check and log the finding — generation mapping still runs.
    if path.isUltraConstrained { return .satellite }
    let info = CTTelephonyNetworkInfo()
    let technology = info.dataServiceIdentifier
        .flatMap { info.serviceCurrentRadioAccessTechnology?[$0] }
    return ConnectionType.cellular(fromRadioAccessTechnology: technology)
}
```

Add `import CoreTelephony`. Simulator/no-SIM reality: `dataServiceIdentifier` is nil there → plain `.cellular`, which is the designed fallback — note it in a comment.
- [ ] **Step 2: Point display sites at the kit mapping.** `ReportDetailView.sensorRows`: delete the local three-case `switch connection` and use `append("antenna.radiowaves.left.and.right", "Connection", connection.displayName)`. `CaptureChecklistView.captured`: split `.connection` out of the `case .battery, .connection, .focus:` group → `case .connection(let raw): return ConnectionType(rawValue: raw).map { "\($0.displayName.uppercased()) CONNECTION" } ?? "\(label) CAPTURED"` (battery/focus keep the old line).
- [ ] **Step 3: Verify** — `swift test` (kit untouched but run anyway), then `xcodebuild build-for-testing` for the DispatchApp scheme. Expected: builds clean, no warnings. Sim smoke: file a report in the simulator — connection row shows "Wi-Fi" (sim network) proving no regression.
- [ ] **Step 4: Commit** — `git commit -m "feat: wired/satellite/cellular-generation connection detection"` → push.

### Task 3: Kit — MediaSample, SensorKind.media, chain policy, v2 field

**Files:**
- Modify: `Sources/DispatchKit/Models/Values.swift` (MediaSample + enums), `Sources/DispatchKit/Capture/SensorSettings.swift` (SensorKind), `Sources/DispatchKit/Capture/SensorProvider.swift` (SensorPayload), `Sources/DispatchKit/Capture/ReportBuilder.swift`, `Sources/DispatchKit/Models/Report.swift`, `Sources/DispatchKit/V2/V2Models.swift`, `Sources/DispatchKit/V2/V2Exporter.swift`, `Sources/DispatchKit/Import/V2Importer.swift`, `Sources/DispatchKit/Capture/SensorFailureHint.swift`
- Create: `Sources/DispatchKit/Capture/MediaChain.swift`
- Test: create `Tests/DispatchKitTests/MediaSampleTests.swift`, `Tests/DispatchKitTests/MediaChainTests.swift`; extend `RoundTripTests.swift`, `V2ExportTests.swift`, `ReportBuilderTests.swift`, `SensorFailureHintTests.swift`

**Interfaces (produced — Tasks 4/5 rely on these exact names):**
- `MediaSource: String` enum — `appleMusic, spotify, otherAudio` — with `displayName` ("Apple Music", "Spotify", "Other audio")
- `MediaPlaybackState: Int` enum — `stopped = 0, playing = 1, paused = 2`
- `MediaSample { source: MediaSource?, sourceRaw: String, title/artist/album: String?, playbackStateRaw: Int, playbackState: MediaPlaybackState? }` + `init(source:title:artist:album:playbackState:)` + `detailLine: String`
- `SensorKind.media` (raw "media"), `SensorPayload.media(MediaSample)`, `Report.media: MediaSample?`, `V2Report.media: MediaSample?`
- `MediaChain.resolve(music: MediaSample?, spotify: () async -> MediaSample?, otherAudioPlaying: () -> Bool) async -> MediaSample?`

- [ ] **Step 1: Write the failing tests.** `MediaSampleTests`: JSON wire keys are `source`/`playbackState` (encode a sample, assert key presence); unknown `source: "vinyl"` decodes with `source == nil` and `sourceRaw == "vinyl"` preserved through re-encode; unknown `playbackState: 9` decodes with `playbackState == nil`; `detailLine` formats: title+artist+spotify → `"Song — Artist, via Spotify"`; title only → `"Song, via Apple Music"`; otherAudio → `"Audio playing"`. `MediaChainTests` (the degrade-through contract, verbatim from the design decision): music sample present → returned, spotify closure NEVER invoked (assert via a flag); music nil + spotify returns sample → spotify sample; **music nil + spotify returns nil (simulating failure/timeout) + otherAudio true → `.otherAudio` sample with playing state — the explicit Spotify-timeout→otherAudio test**; all nil + otherAudio false → nil. `ReportBuilderTests`: `.media: .captured(.media(sample))` outcome lands on `report.media`. `RoundTripTests`/`V2ExportTests`: report with media round-trips all fields; pre-media v2 payload (no `media` key) imports with nil (absence tolerance); nil media is OMITTED from encoded JSON. `SensorFailureHintTests`: `hint(for: .media, reason: "Nothing playing") == "Nothing playing"`.
- [ ] **Step 2: Run `swift test` — expect FAIL** (types don't exist).
- [ ] **Step 3: Implement.** In `Values.swift`:

```swift
public enum MediaSource: String, Codable, Sendable {
    case appleMusic, spotify, otherAudio
    public var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .otherAudio: "Other audio"
        }
    }
}

public enum MediaPlaybackState: Int, Codable, Sendable {
    case stopped = 0, playing = 1, paused = 2
}

/// What was audibly playing at report time. Source and playback state are
/// stored raw (the ConnectionType leniency precedent): unknown values from
/// future exports import, persist, and re-export untouched.
public struct MediaSample: Codable, Hashable, Sendable {
    public var sourceRaw: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var playbackStateRaw: Int

    enum CodingKeys: String, CodingKey {
        case sourceRaw = "source", title, artist, album
        case playbackStateRaw = "playbackState"
    }

    public init(source: MediaSource, title: String? = nil, artist: String? = nil,
                album: String? = nil, playbackState: MediaPlaybackState = .playing) {
        self.sourceRaw = source.rawValue
        self.title = title
        self.artist = artist
        self.album = album
        self.playbackStateRaw = playbackState.rawValue
    }

    public var source: MediaSource? { MediaSource(rawValue: sourceRaw) }
    public var playbackState: MediaPlaybackState? { MediaPlaybackState(rawValue: playbackStateRaw) }

    /// Report-detail line, e.g. "Song — Artist, via Spotify"; the other-audio
    /// floor has no metadata and renders as "Audio playing".
    public var detailLine: String {
        guard source != .otherAudio else { return "Audio playing" }
        let song = [title, artist].compactMap(\.self).joined(separator: " — ")
        let via = source.map { ", via \($0.displayName)" } ?? ""
        return song.isEmpty ? "Media playing\(via)" : "\(song)\(via)"
    }
}
```

New `MediaChain.swift`:

```swift
import Foundation

/// Degrade-through media resolution (plan 26): Apple Music → Spotify →
/// other-audio floor. Each level falling through is NORMAL, not an error —
/// a Spotify read failure or timeout still reaches the floor. Returns nil
/// ONLY when nothing is audible (documented choice: nil = silence, payloads
/// stay lean).
public enum MediaChain {
    public static func resolve(
        music: MediaSample?,
        spotify: () async -> MediaSample?,
        otherAudioPlaying: () -> Bool
    ) async -> MediaSample? {
        if let music { return music }
        if let spotifySample = await spotify() { return spotifySample }
        return otherAudioPlaying() ? MediaSample(source: .otherAudio) : nil
    }
}
```

Wiring (each one line, all additive): `SensorKind` gains `case media` appended to the first case row; `SensorPayload` gains `case media(MediaSample)`; `Report` gains `public var media: MediaSample?`; `ReportBuilder.save` switch gains `case .media(let sample): report.media = sample`; `V2Report` gains `public var media: MediaSample?` (with the standard "omitted when nil; import tolerates absence" doc comment); `V2Exporter` gains `dto.media = r.media`; `V2Importer` gains `report.media = dto.media`. `SensorFailureHint`: add `.media` to the reason-pass-through group (`case .altitude, .battery, .connection, .media:`) and `case .media: "Media"` in `label(for:)` — the exhaustive switches force both.
- [ ] **Step 4: Run `swift test` — expect PASS.** The `SensorKind.allCases`-driven code (settings toggles) now includes `.media`; kit compiles because `SensorSettings` is table-driven. NOTE: the App target will NOT build until Task 4 adds the app-side exhaustive-switch cases (`SensorSettingsView.displayName`, `CaptureChecklistView`) — that is expected and why Tasks 3+4 land as adjacent commits.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): media sample value, sensor kind, degrade-through chain, v2 field"` → push.

### Task 4: App — MediaProvider (Apple Music + floor), permission cascade, toggle, detail row

**Files:**
- Create: `App/Sources/Providers/MediaProvider.swift`
- Modify: `App/Sources/Survey/SurveyController.swift` (provider registration + mock), `App/Sources/Privacy/PermissionCascade.swift`, `App/Sources/Settings/SensorSettingsView.swift` (displayName + MEDIA section placeholder), `App/Sources/Reports/ReportDetailView.swift` (media row), `App/Sources/Survey/CaptureChecklistView.swift` (`.media` captured case), `project.yml` (usage string)

**Interfaces:**
- Consumes: Task 3's `MediaSample`, `MediaChain`, `SensorKind.media`, `SensorPayload.media`, `detailLine`.
- Produces: `protocol SpotifyNowPlayingReading: Sendable { func currentSample() async -> MediaSample? }` and `struct NoSpotify: SpotifyNowPlayingReading` (always nil) — Task 5 supplies the real reader through this exact seam.

- [ ] **Step 1: MediaProvider.** New file:

```swift
import AVFAudio
import DispatchKit
import Foundation
import MediaPlayer

/// Spotify seam: Task 4 ships the always-nil stub; Task 5's App Remote
/// reader conforms. Any failure returning nil DEGRADES to the next chain level.
protocol SpotifyNowPlayingReading: Sendable {
    func currentSample() async -> MediaSample?
}

struct NoSpotify: SpotifyNowPlayingReading {
    func currentSample() async -> MediaSample? { nil }
}

struct MediaProvider: SensorProvider {
    let kind = SensorKind.media
    let spotify: any SpotifyNowPlayingReading

    enum MediaProviderError: Error { case nothingPlaying }

    func capture() async throws -> SensorPayload {
        let sample = await MediaChain.resolve(
            music: await Self.appleMusicSample(),
            spotify: { await spotify.currentSample() },
            otherAudioPlaying: { AVAudioSession.sharedInstance().isOtherAudioPlaying }
        )
        // nil = nothing audible (documented in MediaChain): surfaces as
        // .unavailable("Nothing playing") so report.media stays nil.
        guard let sample else { throw MediaProviderError.nothingPlaying }
        return .media(sample)
    }

    /// Level 1: the system Music player. Only when the media library is
    /// authorized AND actually playing a known item. MPMusicPlayerController
    /// is main-thread-affine (VERIFY against current docs at implementation).
    @MainActor
    static func appleMusicSample() -> MediaSample? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let player = MPMusicPlayerController.systemMusicPlayer
        guard player.playbackState == .playing, let item = player.nowPlayingItem else { return nil }
        return MediaSample(source: .appleMusic, title: item.title, artist: item.artist,
                           album: item.albumTitle, playbackState: .playing)
    }
}
```

Make the thrown error carry the reason string the coordinator records: match how existing providers produce `.unavailable(reason:)` (check `CaptureCoordinator.resolve`'s error→reason mapping and conform — if it stringifies the error, give `MediaProviderError` a `LocalizedError` description of "Nothing playing").
- [ ] **Step 2: Registration + mock.** `SurveyController.providers(since:)`: add `MediaProvider(spotify: SpotifyReaderFactory.current())` — for this task `SpotifyReaderFactory.current()` returns `NoSpotify()` (a one-function enum in MediaProvider.swift; Task 5 replaces the body). `MockProviders.all`: add `Mock(kind: .media, payload: .media(MediaSample(source: .spotify, title: "Song 2", artist: "Blur")))` — then grep `AppUITests/` for checklist/sensor-row count assertions and update any that enumerate mock sensor rows.
- [ ] **Step 3: Permission cascade.** `PermissionCascade`: new `static let mediaLibraryRequestedKey = "permissions.mediaLibraryRequested"`; `requestAll()` sets it true alongside the motion/medications flag and awaits a new `requestMediaLibrary()` between `requestPhotos()` and `requestFocus()`; `runUpgradeTopUpIfNeeded()` gains a second, independently-keyed guard block (same flag-written-BEFORE-steps crash-tolerance comment discipline) running just `requestMediaLibrary()` for installs that onboarded pre-media. Implementation mirrors the focus step:

```swift
private func requestMediaLibrary() async {
    guard MPMediaLibrary.authorizationStatus() == .notDetermined else { return }
    let resumeGate = OneShotResumeGuard()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        MPMediaLibrary.requestAuthorization { _ in
            if resumeGate.claim() { continuation.resume() }
        }
    }
}
```

`import MediaPlayer` joins the file's imports. Test env stays a full bypass (existing guard).
- [ ] **Step 4: Surfaces.** `project.yml` DispatchApp settings: `INFOPLIST_KEY_NSAppleMusicUsageDescription: "Dispatch notes what's playing (song, artist, album — never any audio) when you file a report."` then `xcodegen generate`. `SensorSettingsView`: `extension SensorKind.displayName` gains `case .media: "Media"` (exhaustive switch forces it — toggle appears automatically via `allCases`). `CaptureChecklistView.captured`: `case .media(let sample): return sample.detailLine.uppercased()`. `ReportDetailView.sensorRows`, after the connection row: `if let media = report.media { append("music.note", "Media", media.detailLine) }` — renders "Song — Artist, via Spotify" style per spec.
- [ ] **Step 5: Verify** — `swift test`, `xcodebuild build-for-testing`. Sim smoke: file a report with Music playing in the sim (or assert the "Nothing playing" checklist hint when silent). Expected: media row appears in report detail; toggle listed in Settings → Sensors; toggling off yields `.disabled`.
- [ ] **Step 6: Commit** — `git commit -m "feat: media sensor — Apple Music + other-audio capture, cascade, settings"` → push.

### Task 5: Spotify — SDK, connect/disconnect settings, App Remote reader

**Files:**
- Create: `App/Sources/Spotify/SpotifyConfig.swift`, `App/Sources/Spotify/SpotifyTokenStore.swift`, `App/Sources/Spotify/SpotifyController.swift`, `App/Sources/Spotify/SpotifyNowPlayingReader.swift`, `App/Sources/Settings/SpotifySettingsView.swift`
- Modify: `project.yml` (SDK dependency), `App/Info.plist` (URL scheme, queries scheme, config keys), `App/Sources/DispatchApp.swift` (`onOpenURL` routing), `App/Sources/Settings/SensorSettingsView.swift` (MEDIA section link), `App/Sources/Providers/MediaProvider.swift` (`SpotifyReaderFactory.current()` returns the real reader when connected)

**Interfaces (consumed):** Task 4's `SpotifyNowPlayingReading` seam, Task 3's `MediaSample`.

> **Verification mandate:** every claim below about the Spotify SDK (type names, connect lifecycle, token delivery, packaging) is plan-level belief, NOT established fact. Verify each against https://developer.spotify.com/documentation/ios before writing code; record findings (and divergences) as code comments and in the task report.

- [ ] **Step 1: SDK distribution verification (its own deliverable).** The SDK ships as `SpotifyiOS.xcframework` (github.com/spotify/ios-sdk). Check SPM consumability EMPIRICALLY: if the repo's current release carries a usable `Package.swift`/binary target, add it under `packages:` in project.yml and prove with a build. If not SPM-consumable, vendor the xcframework: commit it at `Vendor/SpotifyiOS.xcframework` and declare it in XcodeGen terms on the DispatchApp target — `dependencies: - framework: Vendor/SpotifyiOS.xcframework, embed: true` — then `xcodegen generate` + build to prove linkage. Document which path was taken and why in project.yml comments (house style).
- [ ] **Step 2: Config + plist.** `App/Info.plist`: add `SpotifyClientID` (from the Spotify developer-dashboard app registration — Robbie provides the value; commit a placeholder string and flag it in the report if unavailable) and `SpotifyRedirectURI` = `dispatch-spotify://callback`; add `LSApplicationQueriesSchemes` = `["spotify"]` (canOpenURL check for "Spotify installed"); extend `CFBundleURLTypes` with a second entry, scheme `dispatch-spotify` (kept separate from the widget-tap `dispatch` scheme so routing stays unambiguous). `SpotifyConfig.swift` reads both keys from the main bundle's info dictionary — nil-safe: missing config renders SpotifySettingsView's connect button disabled with an explanatory footnote, never crashes.
- [ ] **Step 3: Token store.** `SpotifyTokenStore.swift`: minimal SecItem generic-password wrapper (service `"io.robbie.Dispatch.spotify"`, account `"access-token"`) with `save(_ token: String)`, `load() -> String?`, `delete()` — grep-verified there is no existing Keychain helper in the repo to reuse. Tokens NEVER touch UserDefaults or synced storage.
- [ ] **Step 4: Connect/disconnect flow.** `SpotifyController.swift` (`@MainActor @Observable`, test-env no-op via the standard `--ui-testing`/`--mock-sensors` gate): `connect()` builds `SPTConfiguration(clientID:redirectURL:)` and calls `SPTAppRemote.authorizeAndPlayURI("")` (wakes Spotify, runs auth, returns to us via the redirect URI — VERIFY name + semantics); `handleCallback(url:)` extracts the token via `SPTAppRemote.authorizationParameters(from:)` (VERIFY) → `SpotifyTokenStore.save`; `disconnect()` deletes the token. `isConnected: Bool` = token exists. `DispatchApp.onOpenURL`: route `url.scheme == "dispatch-spotify"` to `spotifyController.handleCallback(url:)` BEFORE the existing `dispatch`-scheme guard (which stays untouched). `SpotifySettingsView.swift`: status line (Connected / Not connected / Spotify app not installed via canOpenURL), Connect and Disconnect buttons, privacy footnote ("Dispatch reads only the currently playing track"), identifiers `spotify-connect`, `spotify-disconnect`, `spotify-status`. Entry point: `SensorSettingsView` gains a MEDIA section (below FOCUS FILTER, same styling) with a `NavigationLink("Spotify", destination: SpotifySettingsView())` + current status caption, identifier `spotify-settings-link`.
- [ ] **Step 5: The reader.** `SpotifyNowPlayingReader.swift` conforms to `SpotifyNowPlayingReading`: `currentSample()` returns nil immediately when no token; otherwise connect-read-disconnect — set `appRemote.connectionParameters.accessToken`, `appRemote.connect()`, on `appRemoteDidEstablishConnection` call `playerAPI.getPlayerState` and map (`track.name` → title, `track.artist.name` → artist, `track.album.name` → album, `isPaused` → `.paused`/`.playing`, source `.spotify`), then `appRemote.disconnect()` (VERIFY all names + delegate lifecycle against the docs). The whole read races an internal 5-second budget (inside the coordinator's 10s sensor timeout) via the one-shot-continuation pattern used by `CaptureCoordinator.resolve`; timeout, connection failure (`didFailConnectionAttemptWithError`), missing Spotify app, stale token — ALL return nil so `MediaChain` degrades to the other-audio floor (the kit tests from Task 3 already pin that fallback; add an app-side unit test only if a reader seam is extractable without the SDK — otherwise the kit chain tests carry the contract). Update `SpotifyReaderFactory.current()`: real reader when `SpotifyTokenStore.load() != nil` and not test env, else `NoSpotify()`.
- [ ] **Step 6: Verify** — `swift test`, `xcodebuild build-for-testing`; UI suite at the merge gate (settings screen renders under `--ui-testing` with the controller no-op'd — no SDK traffic). Manual device check (Spotify requires the real app): connect, play a track, file a report → detail shows "Song — Artist, via Spotify"; kill Spotify auth and confirm the floor still records "Audio playing" when other audio runs. Record findings.
- [ ] **Step 7: Commit** — `git commit -m "feat: Spotify now-playing via App Remote — connect flow, keychain token, reader"` → push. Whole-branch review follows (controller-driven).
