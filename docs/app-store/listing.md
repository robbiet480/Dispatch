# Dispatch — App Store listing kit

*Plan 23, Task 4. Copy is deliberately specific and superlative-free
(2.3.1 metadata rules); health integration is stated in the description
because 2.5.1 requires it. Character limits: name 30, subtitle 30,
keywords 100, promotional text 170.*

## Identity

| Field | Value | Notes |
|---|---|---|
| App name (ASC) | `Dispatch - Life Logger` | Already registered on ASC; plain "Dispatch" is taken. 22/30 chars |
| Home-screen name | `Dispatch` | `CFBundleDisplayName`, already set |
| Subtitle | `Randomly timed self-tracking` | 28/30 chars |
| Primary category | Lifestyle | Matches the genre Reporter shipped in |
| Secondary category | Health & Fitness | Honest signal given the Health integration |
| Price | Free | No IAP |
| Privacy Policy URL | `https://robbiet480.github.io/Dispatch/privacy-policy` | GitHub Pages, see docs/privacy-policy.md hosting note |

## Description

```
Dispatch asks you a short set of questions a few times a day, at
moments you don't pick — how you're feeling, what you're doing, who
you're with — and quietly attaches the context of that moment. Answer
enough of them and a picture of your life emerges that no
end-of-day journal can match, because it was sampled while it
happened.

Each report can capture, with your permission:
• Where you are, and the weather there
• Apple Health context: steps, flights, heart rate, HRV, sleep,
  workouts, caffeine, Activity rings — and, if you choose, the
  medications you logged in the Health app
• Ambient loudness as a single decibel number (nothing is recorded)
• Photos taken since your last report (a count, never the photos)
• Battery, connectivity, and which Focus was on

Everything is a question you control: write your own, pick from a
community catalog, or import the questions you used in Reporter.
Number questions come with slider, stepper, dial, tap-counter, and
scale inputs. Answers can log State of Mind entries to Apple Health.

People you mention get stable identities: rename someone and your
history follows, merge duplicates, and — if you turn it on — get
name suggestions and photos from your contact book. Contact matching
stays on your device; nothing from Contacts is uploaded or synced.

Prompting is flexible: a global random schedule with quiet hours,
plus prompt groups that fire on their own schedule — every few hours,
at fixed times, when a workout ends, or when you arrive somewhere
(using power-efficient visit detection; only if you set it up).
Focus filters mute the groups you choose while a Focus is on. Nag
reminders can re-ping you until you answer.

Your data works for you:
• Charts of every answer over time, plus an insights view that
  surfaces patterns ("reports mentioning gym average more steps")
• A weekly digest written on device with Apple Intelligence, with a
  built-in fallback summary
• Full-text and Spotlight search
• Home and lock screen widgets, and a Control Center button that
  starts a report in one tap
• Export everything as JSON or CSV, automatic daily backups (Files
  app and your own iCloud Drive), and one-button Delete All Data
• Optional webhooks: send each report's JSON to a URL you choose —
  your home-automation server, your own service — with signing and
  encryption options

Privacy, plainly: there is no server, no account, no analytics, and
no third-party code. Data stays on your device and — if you leave
iCloud Sync and iCloud Drive backups on — in your own private iCloud
storage, which includes the Health readings attached to your reports.
Turn those off and nothing leaves the device unless you point a
webhook somewhere yourself. Full policy inside the app and at the
privacy policy link.

Dispatch is an independent, open-source reimplementation inspired by
Reporter, the discontinued self-tracking app — original code and
design, and it imports your old Reporter export directly.
```

## Keywords (100 chars max)

```
self tracking,quantified self,life log,journal,diary,mood,check in,survey,reporter,felton,data,csv
```
98/100 chars. Rationale: exact-match phrases people used to find
Reporter and its successors; "felton" catches original-app searches;
no competitor app names beyond the discontinued app Dispatch openly
credits.

## Promotional text (editable without review, 170 max)

```
Random check-ins with real context: location, weather, Health,
Focus. On device and in your own iCloud — no server, no account, no
analytics.
```

## What's New — 1.0 draft

```
First App Store release. Random survey prompts, prompt groups
(timed, workout-end, and arrival triggers), Focus filters, Apple
Health capture including medications and State of Mind, charts,
insights, a weekly on-device digest, widgets and a Control Center
button, people management with optional contact suggestions, iCloud
sync, JSON/CSV export, automatic backups to Files and iCloud Drive,
webhooks, and Reporter import.
```

## Age rating questionnaire

Every content question — violence, sexual content, profanity, horror,
gambling, contests, drugs — answers **None**. Specific answers worth
noting:

| Question | Answer | Why |
|---|---|---|
| Medical/Treatment Information | **None** | Dispatch displays the user's own Health data and logs medication *events they already recorded*; it gives no medical information or advice |
| Alcohol, Tobacco, or Drug Use or References | None | Medication logging is the user's own data, not drug references/content |
| Unrestricted Web Access | No | No web views |
| Gambling and Contests | No | — |
| Made for Kids | No | — |

Expected rating: **4+**.

## Additional ASC settings

- **Content rights:** does not contain third-party content.
- **Export compliance:** uses only exempt (OS-provided) encryption —
  `ITSAppUsesNonExemptEncryption` NO already in the Info.plist, so ASC
  won't re-ask per build.
- **App uses IDFA:** No.

---

## Wrap: launch-gate status (plan 23 completion note)

Task 1's risk register (see [review-readiness.md](review-readiness.md)):

1. **5.1.3(ii) health-in-iCloud — OWNER-ACCEPTED, not a code gate.**
   Ship as-is; reviewer notes carry the snapshot/private-DB framing;
   escalation ladder ends at the local-only health sidecar (2–4 d) if
   Apple rejects twice. Labels + policy + this listing all *disclose*
   the sync rather than deny it — consistency check in
   [privacy-labels.md](privacy-labels.md).
2. **Delete All Data — RESOLVED** (shipped, commit `2c196fb`).
3. **Three-way labels/policy/code consistency — DONE** in
   privacy-labels.md against this branch.

Remaining pre-submission checklist (not code):
- Verify `aps-environment=production` in the release archive (2.3.1
  watch item).
- Optional 1 h: rewrite the four onboarding headlines that match the
  original Reporter's (4.1 belt-and-braces; low risk as-is).
- Run `./scripts/screenshots.sh` on the release build and upload the
  6.9" set.
