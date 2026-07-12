# Dispatch — App Privacy ("nutrition label") answer sheet

*Plan 23, Task 4. Mapped to actual data flows at the current codebase
state; taxonomy per Apple's App Privacy Details
(<https://developer.apple.com/app-store/app-privacy-details/>).
Position on health-data-in-iCloud: OWNER-ACCEPTED risk (see
[review-readiness.md](review-readiness.md) §1) — the labels DISCLOSE
health syncing to the user's private iCloud database; they do not hide
or deny it.*

## Framing decisions (read first)

1. **"Collected" =** transmitted off device. With iCloud Sync default
   ON, synced data counts as collected even though it only reaches the
   user's own private CloudKit database. Apple's taxonomy has no
   "user's own iCloud" carve-out, and private-database records are
   keyed to the user's Apple Account → **"Data Linked to You."**
2. **Not used for tracking** — nothing is shared with data brokers or
   used for cross-app advertising. Tracking answer: **No** across the
   board.
3. On-device-only context (battery, Focus name, audio dB, photo
   metadata) still syncs as part of the report → declared under the
   category that fits it, linked, app-functionality only.
4. Catalog submissions go to the CloudKit **public** DB carrying an
   opaque per-container CloudKit creator ID (not name/email/Apple ID,
   never displayed) → declared collected, **not linked to you** — the
   identifier is not tied to the user's identity in any way available
   to us; documented here in case a reviewer asks.
5. **Contacts: Not Collected.** The optional contact-suggestions
   feature (off by default) and the person↔contact linker read names/
   photos on device only; the link cache (contact identifier +
   email/phone match keys) is device-local, never synced or exported,
   and thumbnails are live-fetched, never persisted. Under Apple's
   definition, data processed on device that is never transmitted is
   not "collected" — and it is not collected by the developer in any
   sense. If a chosen contact's *name* is inserted as a person, that
   name syncs as part of the already-declared User Content, not as
   contact data.
6. **Webhooks change nothing in the label.** The optional webhook
   feature transmits report data only to a single endpoint the user
   configures themselves (off by default, device-local config). The
   developer and no third-party partner receive anything; a
   user-directed transfer to the user's own chosen destination is not
   developer/partner collection under Apple's definitions. The already-
   declared report categories cover the data involved; documented here
   for the reviewer.
7. Backups (default destination: local + the user's own iCloud Drive)
   ride the same reasoning as sync: user's own iCloud storage, covered
   by the categories already declared as collected/linked.
8. **Spotify: opt-in, third-party-partner User ID (not tracking).** The
   optional "Connect Spotify" feature (off by default) authorizes via
   Spotify's App Remote SDK; Dispatch keeps only an access token in the
   Keychain and reads now-playing. When a user connects, Spotify (a
   third-party partner) retains the authorization tied to that user's
   Spotify account → declared **Identifiers → User ID: collected by a
   third-party partner, linked, App Functionality, NOT tracking** (no
   IDFA/ATT/SKAdNetwork, no ad frameworks; Spotify's Developer Terms
   forbid ad-network/broker transfer). The now-playing track Dispatch
   reads is report content, already covered by User Content. Basis:
   [spotify-sdk-privacy.md](spotify-sdk-privacy.md).

## Answer sheet (App Store Connect → App Privacy)

**Do you or your third-party partners collect data from this app?** Yes.

| ASC data type | Collected? | Linked to you? | Tracking? | Purpose | What it actually is |
|---|---|---|---|---|---|
| Health & Fitness → Health | **Yes** | **Yes** | No | App Functionality | Snapshot Health readings on reports (steps, flights, heart rate, HRV, resting HR, sleep, workouts, caffeine, Activity rings, medication dose events incl. medication names, State of Mind sample IDs) — synced to the user's private CloudKit DB when sync is on |
| Health & Fitness → Fitness | **Yes** | **Yes** | No | App Functionality | Workout summaries and ring progress attached to reports (same flow as above) |
| Location → Precise Location | **Yes** | **Yes** | No | App Functionality | Report-time coordinates + reverse-geocoded place; also sent to Apple's weather service for conditions. Visit-arrival monitoring is on-device; visits are not stored, only the report the user then files |
| User Content → Other User Content | **Yes** | **Yes** | No | App Functionality | Report answers, free-text notes, people/things/places tokens, question sets, photo *metadata* counts (never photo content), ambient dB number |
| User Content → Other User Content (2nd flow) | **Yes** | **No** | No | App Functionality | Community-catalog question-set submissions (public DB, opt-in, moderated; opaque CloudKit creator ID only) |
| Identifiers → User ID | **Yes** (opt-in) | **Yes** | No | App Functionality | Spotify authorization tied to the user's Spotify account — collected by third-party partner Spotify **only if the user connects Spotify** (opt-in). Dispatch itself receives only an opaque access token (Keychain); no IDFA/IDFV, no cross-app tracking |

**Everything else: Not Collected.** Explicitly including:

| ASC data type | Answer | Why |
|---|---|---|
| Contact Info (name, email, phone…) | Not collected | No accounts; nothing identifying the user is transmitted |
| Identifiers → Device ID | Not collected | No IDFA/IDFV use; CloudKit's internal record keying is Apple infrastructure, not an app-visible identifier. (Identifiers → User ID is collected only on the opt-in Spotify path — declared above, not tracking.) |
| Purchases / Financial Info | Not collected | No commerce, no IAP |
| Browsing / Search History | Not collected | In-app search runs on device only |
| Contacts / Emails or Text Messages | Not collected | Optional on-device suggestion/link features only (off by default); contact data never leaves the device (framing decision 5) |
| Photos or Videos | Not collected | Only counts + metadata are stored (declared under User Content above); image content is never read, copied, or uploaded |
| Audio Data | Not collected | Microphone is sampled to a single dB figure; no recording exists at any point (declared under User Content as the numeric value) |
| Usage Data / Diagnostics | Not collected | Zero analytics/telemetry/crash SDKs |
| Sensitive Info | Not collected | Nothing beyond the health category already declared |

## Three-way consistency check (labels ↔ policy ↔ code)

| Claim | Label | Policy | Code |
|---|---|---|---|
| Health readings (incl. medication names) sync to private iCloud when sync on | Health & Fitness: collected, linked | "iCloud sync" section says so verbatim | `Report.health` + `SyncPolicy` default-on CloudKit mirroring (`App/Sources/Sync/SyncPolicy.swift`) |
| No analytics/ad/tracking third parties | Tracking: No; Usage Data: not collected | "What Dispatch does NOT do" | No analytics/ad/tracking SDKs and no analytics imports; the sole third-party SDK is Spotify's App Remote (`project.yml` → `SpotifyiOS`), opt-in, App-Functionality only |
| Audio is a dB number only | Audio Data: not collected | "Ambient sound level" bullet | `AudioProvider` computes level only; purpose string states it (`project.yml`) |
| Photos: metadata/count only | Photos: not collected; metadata under User Content | "Photo activity" bullet | `PhotosProvider` stores `PhotoRecord` metadata, no image data |
| Contact data never leaves the device (suggestions/link optional, off by default) | Contacts: not collected (framing decision 5) | "Contacts (optional, off by default)" section | `ContactSuggestionProvider` (on-device matching, toggle default OFF), `ContactLinkCache` (app-group defaults, never synced), thumbnails live-fetched only — PR #13 |
| Webhooks send report data only to a user-chosen endpoint; developer receives nothing | No label change (framing decision 6) | "Webhooks (optional, off by default)" section | `WebhookManager`/`WebhookQueuePolicy` (opt-in URL, https or local-only http, Keychain secret, device-local config) — PR #12 |
| Backups reach the user's own iCloud Drive by default | Covered by declared categories (framing decision 7) | "Automatic backups" bullet | `BackupDestination` default `.both`, local-guaranteed fallback (plan 25, commit `9e1a321`) |
| Catalog submissions public, opt-in, pseudonymous | User Content flow 2: collected, not linked | "Community question catalog" section | `CatalogSubmitView` → public DB; moderation via creator record name only |
| Location goes to Apple weather | Location: collected, linked | "Apple services → Weather" | `WeatherProvider` (WeatherKit) |
| Spotify connection is an opt-in third-party-partner User ID | Identifiers → User ID: collected (opt-in), linked, not tracking | "Spotify (optional, off by default)" section | `SpotifyController` OAuth (`app-remote-control` scope), token in Keychain (`SpotifyTokenStore`), now-playing read only (`App/Sources/Spotify/*`) |
| Now-playing track noted on reports (Apple Music / Spotify) | Covered by User Content → Other User Content | "Now playing" bullet | `MediaProvider` chain: Apple Music → Spotify → other-audio (`App/Sources/Providers/MediaProvider.swift`) |
| Delete-all erases iCloud copy | n/a (retention isn't a label field) | "Your data, your controls" | `DeleteAllData` + CloudKit mirroring propagation (commit `2c196fb`) |

Checked 2026-07-10 against this branch plus the person-identity
(PR #13) and webhooks (PR #12) branches merging alongside; re-checked
2026-07-12 for the opt-in Spotify connection (PR #92 findings,
[spotify-sdk-privacy.md](spotify-sdk-privacy.md)). **Re-run this table
if the health sidecar fallback (Mitigation A) ever lands** — Health &
Fitness would flip to "not collected" and the policy's iCloud section
must be rewritten the same day.
