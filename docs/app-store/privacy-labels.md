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

## Answer sheet (App Store Connect → App Privacy)

**Do you or your third-party partners collect data from this app?** Yes.

| ASC data type | Collected? | Linked to you? | Tracking? | Purpose | What it actually is |
|---|---|---|---|---|---|
| Health & Fitness → Health | **Yes** | **Yes** | No | App Functionality | Snapshot Health readings on reports (steps, flights, heart rate, HRV, resting HR, sleep, workouts, caffeine, Activity rings, medication dose events incl. medication names, State of Mind sample IDs) — synced to the user's private CloudKit DB when sync is on |
| Health & Fitness → Fitness | **Yes** | **Yes** | No | App Functionality | Workout summaries and ring progress attached to reports (same flow as above) |
| Location → Precise Location | **Yes** | **Yes** | No | App Functionality | Report-time coordinates + reverse-geocoded place; also sent to Apple's weather service for conditions. Visit-arrival monitoring is on-device; visits are not stored, only the report the user then files |
| User Content → Other User Content | **Yes** | **Yes** | No | App Functionality | Report answers, free-text notes, people/things/places tokens, question sets, photo *metadata* counts (never photo content), ambient dB number |
| User Content → Other User Content (2nd flow) | **Yes** | **No** | No | App Functionality | Community-catalog question-set submissions (public DB, opt-in, moderated; opaque CloudKit creator ID only) |

**Everything else: Not Collected.** Explicitly including:

| ASC data type | Answer | Why |
|---|---|---|
| Contact Info (name, email, phone…) | Not collected | No accounts; Contacts framework never used — "people" are typed free text |
| Identifiers (User ID / Device ID) | Not collected | No IDFA/IDFV use; CloudKit's internal record keying is Apple infrastructure, not an app-visible identifier |
| Purchases / Financial Info | Not collected | No commerce, no IAP |
| Browsing / Search History | Not collected | In-app search runs on device only |
| Contacts / Emails or Text Messages | Not collected | Never accessed |
| Photos or Videos | Not collected | Only counts + metadata are stored (declared under User Content above); image content is never read, copied, or uploaded |
| Audio Data | Not collected | Microphone is sampled to a single dB figure; no recording exists at any point (declared under User Content as the numeric value) |
| Usage Data / Diagnostics | Not collected | Zero analytics/telemetry/crash SDKs |
| Sensitive Info | Not collected | Nothing beyond the health category already declared |

## Three-way consistency check (labels ↔ policy ↔ code)

| Claim | Label | Policy | Code |
|---|---|---|---|
| Health readings (incl. medication names) sync to private iCloud when sync on | Health & Fitness: collected, linked | "iCloud sync" section says so verbatim | `Report.health` + `SyncPolicy` default-on CloudKit mirroring (`App/Sources/Sync/SyncPolicy.swift`) |
| No analytics/third parties | Tracking: No; Usage Data: not collected | "What Dispatch does NOT do" | No third-party dependency exists (`Package.swift` has none; no analytics imports) |
| Audio is a dB number only | Audio Data: not collected | "Ambient sound level" bullet | `AudioProvider` computes level only; purpose string states it (`project.yml`) |
| Photos: metadata/count only | Photos: not collected; metadata under User Content | "Photo activity" bullet | `PhotosProvider` stores `PhotoRecord` metadata, no image data |
| No Contacts access | Contact Info: not collected | "no accounts / Contacts never accessed" | No `import Contacts` anywhere |
| Catalog submissions public, opt-in, pseudonymous | User Content flow 2: collected, not linked | "Community question catalog" section | `CatalogSubmitView` → public DB; moderation via creator record name only |
| Location goes to Apple weather | Location: collected, linked | "Apple services → Weather" | `WeatherProvider` (WeatherKit) |
| Delete-all erases iCloud copy | n/a (retention isn't a label field) | "Your data, your controls" | `DeleteAllData` + CloudKit mirroring propagation (commit `2c196fb`) |

Checked 2026-07-09 against this branch. **Re-run this table if the
health sidecar fallback (Mitigation A) ever lands** — Health & Fitness
would flip to "not collected" and the policy's iCloud section must be
rewritten the same day.
