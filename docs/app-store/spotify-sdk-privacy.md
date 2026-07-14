# Spotify iOS SDK — privacy disclosure findings

*Research task, 2026-07-12. Purpose: figure out exactly what the bundled
Spotify App Remote SDK (`SpotifyiOS` v5.0.1) collects and transmits, so
the App Store privacy nutrition labels, the app's `PrivacyInfo.xcprivacy`,
and the store/policy copy accurately disclose it. The owner is KEEPING the
optional "Connect Spotify" feature; the current copy falsely claims "no
third-party SDKs," and this document is the basis for correcting that.*

*No product code or store-copy files were changed by this research. This
is a findings + recommendations doc; the label/copy edits are a follow-up
the owner makes.*

---

## TL;DR

| Question | Answer |
|---|---|
| Does the SDK / feature constitute **Tracking** (Apple's definition)? | **No.** No IDFA/AppTrackingTransparency, no SKAdNetwork, no ad frameworks linked, the SDK's own manifest sets `NSPrivacyTracking = false`, and Spotify's Developer Terms forbid Dispatch from feeding any Spotify data to ad networks/brokers. |
| Does the SDK ship a **privacy manifest**? | **Yes** — `PrivacyInfo.xcprivacy` in every framework slice, but it declares **nothing**: no tracking, no tracking domains, no collected data types, no required-reason APIs. |
| Is the SDK on **Apple's list of SDKs requiring a manifest + signature**? | **No.** `Spotify` / `SpotifyiOS` / `spotify/ios-sdk` is not on Apple's list of ~90 SDKs. So the mandatory manifest-and-signature rule does not apply to it. (The in-repo framework is in fact **unsigned** — acceptable precisely because it is off-list.) |
| Does the **app's own `PrivacyInfo.xcprivacy`** need changes because of Spotify? | **No required change.** Spotify's code declares no required-reason APIs; Dispatch's Spotify code uses Keychain + `canOpenURL`, neither of which is a required-reason API. `NSPrivacyTracking` stays `false`; no tracking domain to add. |
| Do the **App Store nutrition labels** need changes? | The overall answers ("collect data? Yes"; "Tracking? No") are unchanged. Recommend adding **Identifiers → User ID** (collected by third-party partner Spotify, *linked*, *not* tracking, App Functionality) for the opt-in Spotify path. See §3. |
| Does the **store/policy copy** need changes? | **Yes — this is the real gap.** "No third-party services or SDKs. The dependency list is empty." is now false. Replacement wording in §5. |

---

## The feature, in code (what actually happens on device)

Source: `App/Sources/Spotify/{SpotifyController,SpotifyNowPlayingReader,SpotifyConfig}.swift`;
SDK wired in via `project.yml` (`packages.SpotifyiOS` → `github.com/spotify/ios-sdk` `exactVersion: 5.0.1`).

- **Opt-in only.** Nothing Spotify-related runs until the user taps "Connect
  Spotify" in settings. "Connected" == an App Remote access token exists in
  the **Keychain** (`SpotifyTokenStore`). Under `--ui-testing` / `--mock-sensors`
  the controller is a no-op and makes no SDK calls.
- **Authorize:** `SpotifyController.connect()` builds
  `SPTConfiguration(clientID:redirectURL:)` and calls
  `authorizeAndPlayURI("", …)`. The empty URI means "resume whatever was
  playing" — the app never starts new playback. This wakes the Spotify app
  (custom URL scheme) or, if Spotify isn't installed, falls back to
  `ASWebAuthenticationSession` (the SDK links `AuthenticationServices`). The
  callback returns to Dispatch via the `dispatch-spotify://` redirect;
  `handleCallback(url:)` extracts `SPTAppRemoteAccessTokenKey` and stores the
  **opaque access token** in the Keychain.
- **Read now-playing:** `SpotifyNowPlayingReader` does a short-lived
  connect → `playerAPI.getPlayerState` → disconnect per capture (5 s budget,
  every failure returns `nil`). It reads only `track.name`,
  `track.artist.name`, `track.album.name`, `isPaused`, and `track.uri`. That
  string is attached to the report the user files.
- **Token custody:** the access token never leaves the device except back to
  Spotify to establish the App Remote connection. It is a Keychain credential,
  cleared on disconnect and on Delete-All-Data (`clearCredentialForDataWipe`).

---

## 1. What the SDK transmits, and to whom

### To Spotify's servers (network)
At **authorization** time the OAuth request carries:
- the app's **client ID** and **redirect URI**;
- the requested **scope** — the SDK automatically requests
  **`app-remote-control`** (per Spotify's README; Dispatch requests nothing
  broader). This scope grants remote playback control + reading player state,
  **not** the user's email/profile.
- Because the user is signed into Spotify, Spotify **associates the
  authorization with that user's Spotify account**, and the request carries
  standard connection metadata (IP address, timestamp, device/OS/app info).

Spotify returns an access token. Dispatch receives **only the token** — it
does *not* receive the user's Spotify username, email, or profile.

### To the local Spotify app (IPC, not Dispatch → network)
The **App Remote** connection is brokered by the installed Spotify app on the
same device; the player-state read comes from that app, not a direct network
call by the SDK. (The Spotify app is of course independently talking to
Spotify's servers as it always does.)

### Telemetry / device identifiers — none from the SDK
Verified three ways against the in-repo framework
(`build/DerivedData/SourcePackages/checkouts/ios-sdk/SpotifyiOS.xcframework`,
`ios-arm64` slice):
- **`PrivacyInfo.xcprivacy` is empty** (see §2) — the SDK self-declares no
  data collection and no tracking.
- **`otool -L`** shows the framework links only: `CoreFoundation`,
  **`AuthenticationServices`** (OAuth web fallback), `CoreGraphics`, `UIKit`,
  **`Security`** (Keychain), `libc++`, `Foundation`, `libobjc`, `libSystem`.
  There is **no `AdSupport`, no `AppTrackingTransparency`, no analytics SDK**
  linked or bundled.
- The framework contains no embedded analytics bundle; the only third-party
  code the README acknowledges is MPMessagePack (a serialization library used
  for the App Remote wire protocol, not telemetry).

**Conclusion:** the SDK phones home only for the OAuth handshake and reads
playback state. It does not collect device identifiers or send telemetry to
Spotify beyond what authorization + playback control require.

### What Spotify does with it on *their* side
This is governed by the user's own relationship with Spotify, not by Dispatch:
- Spotify's **privacy policy** says Spotify collects "User Data" and "Usage
  Data" from connected apps/integrations, plus streaming history, device IDs,
  IP, etc., and uses data "to tailor advertising to your interests" and shares
  User/Usage Data with advertising/marketing partners (restricted for under-18
  users). That is Spotify's **first-party** processing of its own user's
  account data — it happens whether or not Dispatch exists, and Dispatch has
  no visibility into or control over it.
- Spotify's **Developer Terms** bind Dispatch: request only needed data
  (§V), **no data sales** (§V.5), **no transfer to any ad network / ad
  exchange / data broker** (§IV.2.e), retention only as long as necessary
  (§V.7). Dispatch complies (token in Keychain, now-playing shown to the user
  in their own report, nothing sold or shared).

---

## 2. Does the SDK carry a privacy manifest, and what does it declare?

**Yes.** Each framework slice ships `PrivacyInfo.xcprivacy`
(`…/SpotifyiOS.framework/PrivacyInfo.xcprivacy`, identical device vs. simulator).
It declares:

```
NSPrivacyTracking        = false
NSPrivacyTrackingDomains = []   (empty)
NSPrivacyCollectedDataTypes = [] (empty)
NSPrivacyAccessedAPITypes   = [] (empty)
```

i.e. Spotify asserts the SDK does **no tracking, collects no data types, and
uses no required-reason APIs**. Framework metadata: `CFBundleShortVersionString
5.0.1`, bundle id `com.spotify.sdk.ios`, min iOS 12.

**Signature:** the in-repo `SpotifyiOS.framework` is **unsigned**
(`codesign -dvvv` → "code object is not signed at all"; no `_CodeSignature`).
Apple's signature requirement applies only to SDKs on the required list
(§4) — Spotify is not on it — so the missing signature is not a submission
blocker. The app is re-signed as a whole at build/export time.

*Caveat on the empty manifest:* an empty `NSPrivacyAccessedAPITypes` is
Spotify's declaration, not an independent audit. If Apple's static analysis
ever flags a required-reason API inside the SDK, that is Spotify's manifest to
fix; Dispatch does not declare required-reason APIs on a bundled SDK's behalf.

---

## 3. Apple App Privacy (nutrition-label) mapping

### Tracking — **No** (unchanged)
Connecting Spotify is **not** tracking under Apple's definition (linking
data with third-party data for targeted advertising / ad measurement, or
sharing with a data broker). Evidence: no IDFA use, no ATT prompt, no
SKAdNetwork, no ad frameworks linked, SDK manifest `NSPrivacyTracking = false`,
and the Developer Terms explicitly forbid ad-network/broker transfer. Keep the
app-wide **Tracking: No** answer.

### Data types implicated by the opt-in Spotify path
Two things happen when a user connects:

1. **A third-party partner (Spotify) collects & retains the connection.**
   Under Apple's definition of "collect" (retained beyond the real-time
   request), Spotify retains the authorization tied to the user's Spotify
   account. Dispatch itself receives only an opaque token, but Apple's labels
   must reflect **third-party partner** collection.
   - **Recommended entry: Identifiers → User ID** — Collected, **Linked to
     you**, **Not** used for tracking, purpose **App Functionality**.
     Rationale: the connection is associated with the user's Spotify account
     on Spotify's servers (the "Sign in with X" pattern). This is the
     conservative, defensible choice and the one most consistent with the
     existing labels' spirit.

2. **The now-playing metadata Dispatch reads** (track/artist/album/URI) is
   attached to the report. This is already covered by the existing **User
   Content → Other User Content** label (report content synced to the user's
   private iCloud). No new label strictly required.
   - *Optional, more conservative:* also declare **Usage Data → Product
     Interaction** (what the user is listening to). Defensible but arguably
     double-counts data already declared as User Content. Owner's call.

### What to change vs. the current answer sheet (`privacy-labels.md`)
- The row **"Identifiers (User ID / Device ID) — Not collected"** becomes
  inaccurate for the Spotify path. Change to **collected (User ID), linked,
  not tracking, App Functionality**, scoped to the opt-in Spotify connection,
  or add a Spotify-specific note explaining the third-party-partner collection.
- The consistency-check row **"No analytics/third parties … No third-party
  dependency exists (`Package.swift` has none)"** is now false — a third-party
  SDK (Spotify) *is* a dependency (`project.yml` → `SpotifyiOS`). Update that
  row to describe the opt-in Spotify SDK and its App-Functionality-only use.
- Keep **Tracking: No** everywhere. Keep Health/Location/User Content rows.

*(These are edits to the answer-sheet doc + the human-entered ASC labels,
made as a follow-up — not part of this research commit.)*

---

## 4. Compliance requirements (Apple third-party-SDK rules, Spring 2024)

- **Is Spotify's SDK on Apple's "commonly-used SDKs that require a privacy
  manifest" list?** **No.** Apple's list
  (developer.apple.com/support/third-party-SDK-requirements/) enumerates ~90
  SDKs (Firebase*, FBSDK*, Alamofire, GoogleSignIn, OneSignal, RxSwift, the
  Flutter plugins, etc.). **Spotify / SpotifyiOS / spotify/ios-sdk is not on
  it.** So the *mandatory* privacy-manifest-and-signature rule for listed SDKs
  does not bind Spotify's SDK. (Apple's broader guidance — any app or SDK that
  collects data or uses required-reason APIs *should* ship a manifest — is
  satisfied anyway: the SDK ships one, declaring nothing.)
- **Signature:** because it's off-list, the unsigned framework is not a
  blocker. No action needed.
- **Does the APP need to add anything to its own `PrivacyInfo.xcprivacy`
  because of Spotify?** **No.**
  - *Required-reason APIs:* Spotify's manifest declares none. Dispatch's
    Spotify code uses the **Keychain** (not a required-reason API — the five
    required-reason categories are File-timestamp, System-boot-time,
    Disk-space, Active-keyboard, and User-defaults) and `canOpenURL`
    (`LSApplicationQueriesSchemes = ["spotify"]`, also not a required-reason
    API). The app already declares `UserDefaults` `CA92.1` for its own reasons;
    nothing new is required for Spotify.
  - *Tracking:* stays `false`; no tracking domain to add
    (`NSPrivacyTrackingDomains` stays empty — the Spotify auth host is
    functional OAuth, and the SDK itself declares no tracking domains).
  - *Collected data types in the manifest:* the now-playing read is report
    content; the manifest already lists `OtherUsageData` and the report
    content is otherwise covered. No manifest change is *required*; the
    nutrition-label (ASC) and copy changes are where the disclosure actually
    lands.
- **Info.plist entries the SDK needs** (already present per `project.yml`):
  `LSApplicationQueriesSchemes` = `["spotify"]` and a `CFBundleURLTypes`
  redirect scheme (`dispatch-spotify`). These are functionality, not privacy
  declarations.

---

## 5. Honest replacement wording for the "no third-party SDKs" claim

The false statements to fix (store copy — **owner edits these**, not part of
this research commit):

- `docs/privacy-policy.md` line 14: *"No analytics, no ads, no tracking, no
  third-party SDKs."*
- `docs/privacy-policy.md` line 144: *"No third-party services or SDKs. The
  dependency list is empty."*
- `docs/app-store/listing.md` lines 76–77: *"there is no server, no account,
  no analytics, and no third-party code."*
- `docs/app-store/review-notes.md` lines 35–36 / 62: *"no third parties … no
  analytics, no SDKs, no server of ours."*

The claims that stay TRUE and should be preserved: no analytics/telemetry, no
ads, no tracking, no data brokers, no Dispatch server, no account with
Dispatch. The only thing that changed is the addition of one **optional,
user-initiated** third-party SDK.

### Suggested replacements

**Privacy policy — replace the line-14 bullet:**
> **No analytics, no ads, no tracking.** The app makes no network connections
> except to Apple services (iCloud, Apple's weather service, push
> notifications), the shared community catalog (only if you explicitly submit
> a question set), an optional webhook endpoint you choose yourself, and — only
> if you tap "Connect Spotify" — Spotify, to read what you're currently
> playing. Dispatch uses no analytics, advertising, tracking, or data-broker
> SDKs of any kind.

**Privacy policy — replace the line-144 "does NOT do" bullet:**
> - No analytics, advertising, tracking, or fingerprinting SDKs, and no data
>   sales. The only third-party SDK in the app is Spotify's App Remote SDK,
>   used **solely** to read your current track — and **only if you opt in** by
>   connecting Spotify. It requests just the `app-remote-control` permission,
>   stores only an access token in your device Keychain, and is never used for
>   analytics, advertising, or tracking. When you connect, Spotify (as the
>   account provider) sees that you authorized Dispatch; Spotify's use of that
>   is governed by Spotify's own privacy policy. Disconnect any time in
>   Settings, which deletes the token.

**Add a short "Spotify (optional, off by default)" section** to the policy,
mirroring the existing Webhooks/Contacts optional-feature sections:
> **Spotify (optional, off by default).** If you connect Spotify, Dispatch
> reads only your currently-playing track (title, artist, album) to note it on
> a report, using Spotify's official App Remote SDK. Authorization uses the
> `app-remote-control` scope; Dispatch receives only an access token, stored
> in your device Keychain, never your Spotify email or profile. Dispatch never
> sends your data to any advertising network or data broker (Spotify's
> Developer Terms prohibit this, and Dispatch doesn't). Spotify's own handling
> of your account and listening data is covered by Spotify's privacy policy.

**Listing description — replace lines 76–77:**
> Privacy, plainly: there is no server, no account, and no analytics or
> tracking. The only third-party code is Spotify's official SDK — used just to
> read your current track, and only if you connect Spotify yourself. Data stays
> on your device and — if you leave iCloud Sync and iCloud Drive backups on —
> in your own private iCloud storage…

**Review notes — replace lines 35–36 & 62** with, e.g.:
> Now-playing may come from Apple Music (first-party) or, if the user connects
> it, Spotify via Spotify's official App Remote SDK (opt-in; `app-remote-control`
> scope only; token in Keychain). No advertising, no analytics, no data brokers,
> no server of ours. No data is accessible to the developer.

---

## Sources

**In-repo evidence** (paths under `build/DerivedData/SourcePackages/checkouts/ios-sdk/`):
- `SpotifyiOS.xcframework/ios-arm64/SpotifyiOS.framework/PrivacyInfo.xcprivacy`
  — empty tracking/collected/accessed-API declarations.
- `…/SpotifyiOS.framework/Info.plist` — `CFBundleShortVersionString 5.0.1`,
  bundle id `com.spotify.sdk.ios`.
- `otool -L …/SpotifyiOS.framework/SpotifyiOS` — linked frameworks (no ad/analytics).
- `codesign -dvvv …/SpotifyiOS.framework` — "code object is not signed at all."
- App source: `App/Sources/Spotify/*.swift`; wiring: `project.yml`; app manifest:
  `App/PrivacyInfo.xcprivacy`.

**External** (fetched 2026-07-12):
- Apple, *Third-party SDK requirements* (the required list) — <https://developer.apple.com/support/third-party-SDK-requirements/>
- Apple, *Privacy manifest files* — <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- Apple, *Adding a privacy manifest to your app or third-party SDK* — <https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk>
- Apple, *App Privacy Details* (nutrition labels) — <https://developer.apple.com/app-store/app-privacy-details/>
- Spotify iOS SDK repo & README — <https://github.com/spotify/ios-sdk> · <https://github.com/spotify/ios-sdk/blob/master/README.md>
- Spotify iOS SDK auth docs — <https://github.com/spotify/ios-sdk/blob/master/docs/auth.md>
- Spotify iOS SDK docs portal — <https://developer.spotify.com/documentation/ios>
- Spotify Developer Terms — <https://developer.spotify.com/terms>
- Spotify Privacy Policy — <https://www.spotify.com/us/legal/privacy-policy/>
