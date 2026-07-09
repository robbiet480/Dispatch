# Dispatch — App Store Review Readiness Analysis

*Plan 23, Task 1. Researched 2026-07-09 against the live App Store Review Guidelines
(<https://developer.apple.com/app-store/review/guidelines/>, fetched 2026-07-09 — all
guideline quotations below are verbatim from that fetch, not recalled). Codebase audited
at commit `7ab0a94` on `main`.*

---

## 1. Priority finding: HealthKit data in iCloud (Guideline 5.1.3(ii)) — RISK ACCEPTED (owner decision, 2026-07-09)

> **Decision (Robbie, 2026-07-09):** ship as-is and contest if rejected. Rationale: the
> guideline's "personal health information" is undefined and plausibly targets wholesale
> copying of Health data to iCloud, not contextual snapshot readings attached to
> self-tracking reports in the user's own CloudKit **private** database; the clause reads
> as a discretionary catch-all. Escalation ladder: (1) submit as-is with reviewer notes
> framing the snapshot/context distinction, (2) if rejected, respond/appeal with the same
> framing, (3) if still rejected, implement Mitigation A (local-only health sidecar,
> 2–4 days, designed below) as the fallback. Consequences accepted: possible launch
> delay at 1.0 submission time; privacy labels/policy will DISCLOSE health data syncing
> to the user's private iCloud database (transparency aligned with this position).
> The iCloud-Drive backup variant (if ever built) inherits this same accepted risk.
> The analysis below is preserved unedited as the basis for the fallback.

### Current guideline text (fetched 2026-07-09)

> **5.1.3(ii)** — "Apps must not write false or inaccurate data into HealthKit or any
> other medical research or health management apps, **and may not store personal health
> information in iCloud**."
> — <https://developer.apple.com/app-store/review/guidelines/#health-and-health-research>

### What the code actually does

- `Sources/DispatchKit/Models/Report.swift` — `Report.health: [HealthReading]` stores
  captured health metrics inline on every report. `HealthReading` (`Models/Values.swift`)
  is an open-typed `(type, value, unit, startDate, endDate)` record carrying **steps,
  flights, heart rate, HRV, sleep, workouts, caffeine, activity rings — and medication
  dose events** (`medication.<taken|skipped>.<name>` per
  `Sources/DispatchKit/Visualization/MedicationReading.swift`, including the user-facing
  medication name).
- `App/Sources/Sync/SyncPolicy.swift` — CloudKit mirroring of the whole SwiftData store
  is **default ON** for new installs (container `iCloud.io.robbie.Dispatch`, private DB).
  There is no per-field exclusion: when sync is on, every `Report` — health readings and
  medication events included — is mirrored to iCloud.
- `Report.stateOfMindSampleIDs` syncs HealthKit sample **identifiers** only (not
  valence/labels); lower sensitivity, but still a health-context artifact.

### Verdict

**As shipped, Dispatch violates 5.1.3(ii).** HealthKit-sourced readings — including
medication names, an especially sensitive class — are stored in iCloud whenever the
default-on sync toggle is active. The guideline text contains no carve-out for the
user's *private* CloudKit database, no consent exception, and no "derived/summary data"
exception.

**Where Apple's text is ambiguous:** "personal health information" is undefined. Long-
standing enforcement guidance (Apple's original HealthKit rules coverage:
<https://www.mobihealthnews.com/news/apple-bans-icloud-and-7-other-rules-healthkit-developers>;
rejection reporting: <https://www.trustedreviews.com/news/apple-rejecting-healthkit-apps-that-store-personal-data-in-icloud-2918035>;
health-app compliance guides, e.g. <https://blog.dashsdk.com/app-store-requirements-for-health-apps/>)
consistently reads it as **HealthKit-sourced data may not touch iCloud**, and apps have
been rejected on exactly this basis since 2014. Anecdotally some shipping apps sync
HealthKit-derived aggregates via CloudKit without rejection (enforcement is inconsistent
because reviewers can't see server schemas), but that is weak, survivorship-biased
evidence — quality-weighted, the strict reading governs. Medication data pushes this
from "arguable aggregate" to "clearly personal health information." **Treat as a hard
launch gate; do not rely on a reviewer-notes consent framing — no credible precedent
exists for a consent exception to 5.1.3(ii).**

### Mitigation options

| # | Design | Effort | Residual risk |
|---|--------|--------|---------------|
| **A. Local-only health sidecar (recommended)** | Move `health` (and `stateOfMindSampleIDs`) off `Report` into a `HealthSidecar` model keyed by `report.uniqueIdentifier`, held in a second `ModelConfiguration` with CloudKit disabled (SwiftData supports mixed configurations in one `ModelContainer`). Migration copies existing inline readings to the sidecar and blanks the synced field; export/CSV/digest/visualization join through the key. | **2–4 days** (model split, migration, join plumbing in export/digest/viz, test updates) | Near zero. Health data never leaves the device; sync keeps everything else. UX cost: health context doesn't follow reports to a second device. |
| **B. Sync-excluded fields with on-device re-capture** | Keep the schema, mark health fields non-synced, and on a receiving device re-query HealthKit for the report's timestamp window to reconstruct readings locally. | **4–6 days** (everything in A plus a re-capture engine + permission/edge handling) | Low guideline risk, but lossy (medication events and point-in-time HR won't reconstruct faithfully) and doubles the surface for bugs. Only worth it if cross-device health display is a must-have. |
| **C. Health-sync opt-in toggle + reviewer-note framing** | Default health readings out of sync; a buried toggle re-enables with explicit consent language. | **0.5–1 day** | **Still noncompliant when enabled** — 5.1.3(ii) has no consent carve-out. Rejection risk stays material; also creates a 2.3.1 honesty problem in the privacy labels. Not viable alone. |

**Recommendation: Option A.** Smallest honest design that satisfies the strict reading,
preserves the medications feature intact on-device, and keeps the privacy story ("your
health data never leaves your phone") simple enough to state verbatim in the privacy
policy, labels, and reviewer notes. Sequence it before any submission.

---

## 2. Other findings (codebase-verified)

### 2.1 HealthKit purpose & usage — 2.5.1 / 5.1.3(i) — PASS
2.5.1: "HealthKit should be used for health and fitness purposes and integrate with the
Health app." 5.1.3(i) bans advertising/data-mining use and requires disclosing "the
specific health data that you are collecting."
Audit: readings are displayed to the user only (viz/digest/report detail); no third
parties, no analytics SDKs anywhere in the tree. Purpose strings in `project.yml`
enumerate the exact types read ("steps, flights, heart rate, HRV, sleep, workouts, and
caffeine… State of Mind entries") and the write string covers State of Mind logging
(`App/Sources/Health/StateOfMindWriter.swift`). Entitlements (`App/Dispatch.entitlements`)
carry healthkit + background-delivery, matching actual use. **Action:** app description
must mention Health integration (2.5.1 "indicate that integration in their app
description") — feed to Task 4. Medications ride the same read path; disclose the
medications type explicitly in the description/labels.

### 2.2 Always-location for visit triggers — 5.1.5 — PASS with reviewer notes
5.1.5: "Use Location Services in your app only when it is directly relevant… be sure to
explain the purpose in your app."
Audit: `App/Sources/Providers/VisitObserver.swift` uses `CLVisit` monitoring;
`requestAlwaysAuthorization()` is invoked **contextually from
`PromptGroupsView.swift` only when the user schedules an arrival-triggered prompt
group** — exactly the recommended pattern. The Always purpose string says so
("power-efficient visit detection… Only used if a prompt group is scheduled on
arrivals"). Good story; document verbatim in Task 4 reviewer notes so the reviewer knows
how to surface the prompt (create a visit-arrival prompt group).

### 2.3 Face ID / microphone / photos / motion / focus purpose strings — PASS
All present in `project.yml` and truthful: mic string states "a decibel number only, no
recording is kept" (matches `SensorProvider` behavior — dB sampling only); photos =
count since last report; Face ID = app lock (`App/Sources/Privacy/AppLock.swift`);
motion = flights descended. No Contacts framework usage anywhere (`import Contacts` /
`CNContact` absent) — the People feature is free-text tokens, so no Contacts permission,
string, or 5.1.2(iv)/(v) exposure. Remove any Contacts mention from listing materials.

### 2.4 Privacy nutrition labels — 5.1.1/5.1.2 + label taxonomy — ACTION REQUIRED
Apple's taxonomy (<https://developer.apple.com/app-store/app-privacy-details/>): data
stored server-side that is tied to the user's identity counts as **"Data Linked to You"**
even in a private CloudKit database, because iCloud records are keyed to the user's
Apple Account. So with sync on, Dispatch must declare Health & Fitness, Location, and
"Other Data Types" (reports) as *collected, linked to you, not used for tracking* —
unless Option A lands, in which case Health & Fitness drops to "not collected" off-device
(on-device-only processing is not "collection" under Apple's definition when data never
leaves the device). Label answers are Task 4; the three-way code/policy/label
consistency check must run **after** the 5.1.3 mitigation to avoid declaring health
collection that no longer happens.

### 2.5 Background modes — 2.5.4-adjacent — PASS
`App/Info.plist`: `UIBackgroundModes = [remote-notification]` only — the standard,
review-safe CloudKit silent-push mode. HealthKit background delivery is via entitlement,
not a UIBackgroundModes entry. No location background mode (CLVisit doesn't need one).

### 2.6 Copycat / minimum functionality — 4.1 / 4.2 — LOW RISK, draft defense
4.1(a): "Don't simply copy the latest popular app… or make some minor changes to another
app's name or UI and pass it off as your own." 4.2 requires the app be "useful, unique,
or 'app-like'."
Audit: Reporter has been discontinued for years (not "the latest popular app"); the name
(Dispatch), bundle ID, icon, and all assets are original; no Reporter-branded assets or
strings ship in the app (repo "Reporter" mentions are code comments citing parity
behavior; `reporter-export.json` is a gitignored-class personal data file, not bundled).
Onboarding: **headlines are the original Reporter's four headlines verbatim** ("Snapshot
your life." / "Control your data." / "Embrace your sensors." / "Make it yours." —
`App/Sources/OnboardingView.swift`); body copy is original prose. Four short common
phrases carry negligible IP/4.1 exposure, but they are the only verbatim copy left —
cheap to rewrite if maximal caution is wanted.
**Defense line (for README + reviewer notes):** "Dispatch is an original, from-scratch
implementation inspired by the discontinued Reporter app (Nicholas Felton, 2014). No
original code, assets, or branding are used; the data model can import Reporter's
documented export format for continuity." 4.2 is comfortably met: sync, widgets,
Control Center, prompt groups, digests, visualizations, backups.

### 2.7 Accounts & data deletion — 5.1.1(v) — GAP (delete-all missing)
5.1.1(v) account-deletion rules are **N/A** (no accounts, no login). However:
`App/Sources/Settings/DataSettingsView.swift` offers JSON/CSV **export** and automatic
Files-app backups, but **no "delete all data" affordance exists anywhere in Settings**
(grep across `Settings/` confirms deletes are per-entity editor actions only). Not a
hard guideline requirement for account-less apps, but it is a GDPR-erasure expectation,
a common reviewer question for health apps, and — with CloudKit — deleting the app does
NOT delete the iCloud copy. **Recommend shipping a "Delete All Data" action (local store
+ CloudKit zone purge) before or alongside 1.0; effort ~1 day.** Feed the gap into the
privacy policy honestly if it slips.

### 2.8 Encryption export compliance — PASS
`ITSAppUsesNonExemptEncryption: NO` (`project.yml`). Still accurate with CloudKit:
the app implements no proprietary encryption; it uses only Apple OS-provided TLS/
CloudKit encryption, which is exempt under category 5A992/mass-market OS-services
carve-outs (<https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>).

### 2.9 Metadata accuracy — 2.3.1 — WATCH
2.3.1(a): "All new features, functionality, and product changes must be described with
specificity in the Notes for Review section… (generic descriptions will be rejected)."
Reviewer notes (Task 4) must walk every permission (esp. Always-location and
medications) and explain how to trigger each. Also: `aps-environment` is `development`
in the checked-in entitlements — release signing must produce `production` (Xcode
handles this at distribution; verify in the archive).

### 2.10 Kids / age rating — PASS
No objectionable content, no web views, no UGC sharing. Age rating questionnaire should
land at 4+; medication logging does not trigger the "Medical/Treatment Information"
higher-rating path since the app provides no medical advice. Answer sheet in Task 4.

---

## 3. Risk register

| Guideline | Finding | Severity | Mitigation | Owner |
|---|---|---|---|---|
| 5.1.3(ii) | HealthKit readings incl. medication names sync to iCloud via default-on CloudKit mirroring | **Blocker** | Option A: local-only health sidecar (2–4 d) | robbiet480 |
| 5.1.1 / privacy | No delete-all-data affordance; CloudKit copy survives app deletion | High | Add Settings → Delete All Data w/ CloudKit purge (~1 d) | robbiet480 |
| Privacy labels | Labels must reflect post-mitigation data flows; CloudKit private DB = "linked to you" | High | Task 4 answer sheet drafted **after** 5.1.3 fix | robbiet480 |
| 2.5.1 | Health integration must be stated in App Store description | Medium | Task 4 listing copy | robbiet480 |
| 2.3.1 | Reviewer notes need specific permission walkthrough; verify `aps-environment=production` in archive | Medium | Task 4 review-notes.md; archive check | robbiet480 |
| 4.1 | Onboarding headlines verbatim from original Reporter | Low | Optional rewrite (~1 h); attribution defense drafted (§2.6) | robbiet480 |
| 5.1.5 | Always-location | Low (compliant) | Document contextual-ask story in reviewer notes | robbiet480 |
| Export compliance | ITSAppUsesNonExemptEncryption=NO | Low (compliant) | None | — |

## 4. Top-3 blockers

1. **5.1.3(ii) — health readings in iCloud.** Gates everything. Implement mitigation A
   before submission; privacy policy/labels/reviewer notes all depend on its outcome.
2. **No delete-all-data affordance** — high-probability reviewer/privacy friction for a
   health-adjacent app with cloud sync; also makes the privacy policy harder to write
   honestly.
3. **Privacy-label / policy / code three-way consistency** — cannot be finalized until
   (1) lands; submitting labels that declare health "not collected" while the current
   code syncs it would be a 2.3.1 honesty violation.

## 5. Recommended submission sequencing

1. Implement 5.1.3 mitigation A (health sidecar, local-only) + migration; suites green.
2. Add Delete All Data (local + CloudKit purge).
3. (Optional, 1 h) Rewrite the four onboarding headlines.
4. Task 4 artifacts: privacy policy → privacy labels → listing copy → reviewer notes,
   each written against the post-mitigation data flows; run the three-way consistency
   check.
5. Archive; verify `aps-environment=production` and the entitlement set matches
   §2 exactly; screenshots (Task 3); submit with detailed reviewer notes
   (permission walkthrough + Reporter-inspiration disclosure + demo instructions).

## 6. Citations

- App Store Review Guidelines (all § quotes, fetched 2026-07-09):
  <https://developer.apple.com/app-store/review/guidelines/>
- App privacy details (nutrition-label taxonomy):
  <https://developer.apple.com/app-store/app-privacy-details/>
- Offering account deletion (confirmed N/A):
  <https://developer.apple.com/support/offering-account-deletion-in-your-app/>
- Encryption export compliance:
  <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>
- 5.1.3 enforcement history (secondary, quality-weighted as corroboration only):
  <https://www.mobihealthnews.com/news/apple-bans-icloud-and-7-other-rules-healthkit-developers>,
  <https://www.trustedreviews.com/news/apple-rejecting-healthkit-apps-that-store-personal-data-in-icloud-2918035>,
  <https://blog.dashsdk.com/app-store-requirements-for-health-apps/>
