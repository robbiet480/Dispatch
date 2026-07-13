# Dispatch — App Privacy ("nutrition label") answer sheet

*Reflects the App Store Connect declaration: **Data Not Collected**. Apple's
definition of "collect" (ASC → Data Collection) is the test — data transmitted
OFF the device in a way that lets you or a third-party partner access it beyond
servicing the real-time request. By that test nothing in Dispatch is collected,
with one documented judgment call (the community catalog) noted below.*

*(Supersedes the earlier "collected/linked" draft, which wrongly counted the
user's own private-iCloud sync — and a bundled control SDK — as collection.)*

## The declaration

ASC → App Privacy → **"Do you or your third-party partners collect data from
this app?" → No (Data Not Collected).** Tracking: **No**.

## Why nothing meets Apple's "collect" definition

Dispatch has no server, no account, no analytics/telemetry, and no
data-collecting SDKs. Every data flow either stays on the device or goes only
to storage neither the developer nor a partner can access:

- **iCloud Sync / backups** — reports (with their Health, location, and
  free-text content) sync via SwiftData's CloudKit mirroring to the user's OWN
  **private** CloudKit database; automatic backups go to the local Files app
  and, optionally, the user's own iCloud Drive. The developer has no access —
  it is the user's own iCloud storage, not a store the developer controls.
  (Default on; Settings → Data → iCloud turns it off; Delete All Data
  propagates erasure.)
- **Weather** — report coordinates are sent to Apple's WeatherKit to fetch
  conditions: an OS service call, serviced in real time.
- **Webhooks** (opt-in, off by default) — send the user's own report JSON to
  the single endpoint the user configures. The destination is the user's, not
  the developer's; nothing comes back to us or a partner.
- **Contacts** (optional, off by default) — name matching and photo fetch
  happen on device; the link cache is device-local, never synced or exported.
- **On-device context** (battery, Focus name, ambient dB number, photo counts,
  motion) is computed on device and only ever rides along inside the user's own
  private-iCloud report above.
- **Spotify** (opt-in, off by default) — "Connect Spotify" uses Spotify's
  official App Remote SDK: a **playback-control + auth** channel to the user's
  OWN Spotify account. Dispatch keeps only a Keychain access token and reads
  now-playing (attached to a report — i.e. the user's own private-iCloud data).
  No Dispatch data is transmitted to a store the developer or Spotify retains
  *from this app*, and App Remote is not on Apple's privacy-manifest SDK list.
  Basis: [spotify-sdk-privacy.md](spotify-sdk-privacy.md).
- **Identifiers / usage** — no IDFA/IDFV, no analytics, no crash SDKs.

## The one judgment call: community catalog

Settings → Questions → Catalog lets a user optionally **submit a question set to
the app's shared, PUBLIC CloudKit database** — the one flow that writes to a
store the **developer** can access (moderation runs against it) and persists
beyond real time. Strictly, that meets Apple's "collect" definition.

We treat it as **not collected** because it is the user **publishing their own
authored question text** — optional and user-initiated, no personal data, and
carrying only an **opaque per-container CloudKit creator ID** that is never tied
to the user's name, email, or Apple ID and is never displayed. The reviewer
notes disclose it.

**If a reviewer disagrees:** flip the ASC answer to "Yes" and declare exactly
ONE item — **User Content → Other User Content, Not Linked to You, App
Functionality** (the catalog question text) — and nothing else changes. That is
the entire delta.

## Consistency check

The in-app privacy screen, `docs/privacy-policy.md`, the App Store descriptions,
and the reviewer notes all say the same thing: data stays on the user's devices
and in the user's own private iCloud; the developer can't see it; the only
third-party SDK (Spotify) is an opt-in control channel to the user's own
account. Keep them in sync if the stance ever changes.

> `review-readiness.md` §1 discusses health-data-in-iCloud under guideline
> 5.1.3(ii) — that is about *where* health data is stored (a separate concern
> from the collection label) and remains valid; its "labels disclose the sync"
> wording predates this stance, so reconcile it if it ever reads as
> contradictory.
