# Dispatch — Notes for Review (App Store Connect)

*Plan 23, Task 4. Paste (trimmed as needed) into ASC → App Review
Information → Notes. Written to satisfy 2.3.1's "describe with
specificity" bar: every permission, how to trigger it, and the two
stories a reviewer is most likely to question (Always location,
medications/health-in-iCloud).*

## Paste-ready reviewer notes

```
Dispatch is a self-tracking app: it prompts the user a few times a day
with their own short questionnaire and attaches sensor context to each
answer. No account or sign-in exists — the app is fully usable the
moment it launches. No demo credentials are needed.

QUICK DEMO PATH
1. Complete onboarding (each permission below is requested in context
   with an explanation screen; all can be denied and the app still
   works).
2. Tap the large REPORT button on the home screen, answer the
   questions, tap DONE. The first survey page shows exactly which
   sensors are being captured for that report.
3. After 2–3 reports the home screen fills with charts. Settings →
   Weekly Digest and Settings → Insights read from the same data.
4. Settings → Data shows export (JSON/CSV), automatic local backups,
   and Delete All Data.

PERMISSIONS, ONE BY ONE
- Notifications: the core mechanic — randomly timed survey prompts.
  Optional "nag" re-reminders use Time Sensitive notifications so a
  deliberately-set reminder can break through Focus.
- Location (When in Use): stamps the report with where it was filed
  and fetches weather via Apple's WeatherKit.
- Location (ALWAYS — the upgrade prompt appears ONLY in one place):
  Settings → Prompt Groups → New Group → schedule "When I arrive
  somewhere". This uses Apple's power-efficient CLVisit monitoring so
  a group of questions can fire on arriving at a location. The Always
  request is made contextually at that moment, never at onboarding.
  If declined, the group type is simply unavailable; nothing else
  changes. Purpose string states this scope.
- Health (read): steps, flights, heart rate, HRV, resting HR, sleep,
  workouts, caffeine, Activity rings — captured as a snapshot on each
  report for the user's own review. Displayed only; never used for
  advertising and never shared with any third party (there are none —
  no analytics, no SDKs, no server of ours).
- Health medications (separate per-object read authorization): only
  requested via its own explanation step; captures dose events the
  user already logged in the Health app, shown back in their reports.
  Dispatch provides no medical advice (age rating: None for
  Medical/Treatment Information).
- Health (write): only State of Mind, and only for questions the user
  explicitly marks to log mood.
- Microphone: sampled to a single decibel number per report. No audio
  is recorded or stored at any time (purpose string says the same).
- Photos: counts photos taken since the previous report; the images
  themselves are never read, copied, or uploaded.
- Motion & Fitness: stairs descended via the motion coprocessor, to
  pair with flights climbed from Health.
- Face ID: optional app lock (Settings → App Lock).
- Focus status: records whether a Focus was active when a report was
  filed; an optional Focus Filter (set up in iOS Settings → Focus)
  lets each Focus mute chosen prompt groups.

HEALTH DATA AND ICLOUD (proactive disclosure)
Dispatch syncs via SwiftData's CloudKit mirroring to the user's OWN
PRIVATE CloudKit database (default on; Settings → Data → iCloud turns
it off). Reports include their attached snapshot Health readings, so
with sync on those snapshots reside in the user's private database —
disclosed in the privacy policy, the App Privacy labels, and the app
description. Our reading of 5.1.3(ii): these are contextual snapshot
readings attached to the user's own self-tracking entries in their
private database — not a wholesale copy of Health data to iCloud, and
nothing is ever accessible to the developer or any third party. Users
who prefer zero off-device health data can disable sync (fully
functional) and Delete All Data propagates erasure to iCloud.

BACKGROUND MODES
remote-notification only — CloudKit's standard silent change pushes.
Workout-end and visit-arrival prompt triggers use HealthKit background
delivery and CLVisit relaunches respectively (no location background
mode needed or present).

COMMUNITY CATALOG (user-generated content)
Settings → Questions → Catalog browses shared question sets from a
public CloudKit database. Submissions contain only question text
chosen by the submitter (never answers/reports), are held for
moderation before appearing, and can be reported/removed; a moderation
tool operates on the same database.

ORIGIN
Dispatch is an original, open-source (MIT) implementation inspired by
Reporter (Nicholas Felton, 2014), which was discontinued years ago.
No original Reporter code, assets, or branding are used; Dispatch
imports Reporter's documented JSON export format so former users keep
their history. Source: github.com/robbiet480/Dispatch
```

## Internal reminders (do not paste)

- Confirm the archive's entitlements before submitting:
  `aps-environment` must read `production` in the exported IPA
  (`codesign -d --entitlements - <app>`), per review-readiness §2.9.
- Contact info fields in ASC: personal email/phone (this is a personal
  app — nothing @campus.edu).
- If the reviewer rejects on 5.1.3(ii), respond with the framing above
  (step 2 of the accepted-risk escalation ladder in
  review-readiness.md §1) before building the sidecar fallback.
- Catalog moderation must be responsive during review week: run
  `swift run dispatch-mod dashboard` daily so a reviewer-submitted
  question set doesn't sit unmoderated.
