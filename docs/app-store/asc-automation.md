# App Store Connect listing automation

`scripts/asc-listing.swift` pushes the listing kit in this directory to
App Store Connect: version metadata, screenshots, review details, age
rating, and the build attachment. The markdown files are the single
source of truth — the script parses them at run time and carries no
listing copy of its own.

## The no-submit policy (non-negotiable)

**This automation never submits for review.** There is deliberately no
code path that touches `reviewSubmissions`, `appStoreVersionSubmissions`,
or any submission endpoint — no flag, no environment variable, nothing
to misfire. The script's terminal step prints
`ready for manual submission in App Store Connect`; a human opens ASC,
reviews every staged field, and presses Submit. Keep it that way: any
change that adds a submission call should be rejected in review.

## Setup

1. **API key** — an App Store Connect API key with the **App Manager**
   role (the same key `upload-testflight.sh` uses works). The key role
   cannot be verified through the API, which is one reason the script
   defaults to dry-run.
2. **Files** (both gitignored / outside the repo):
   - `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
   - `scripts/asc-config.local`:

     ```
     ASC_KEY_ID=...
     ASC_ISSUER_ID=...
     # Optional — review-details contact (left untouched when absent):
     ASC_CONTACT_FIRST=...
     ASC_CONTACT_LAST=...
     ASC_CONTACT_PHONE=...
     ASC_CONTACT_EMAIL=...
     ```
3. **Screenshots** — run `./scripts/screenshots.sh` first; the script
   reads `docs/app-store/screenshots/` and maps the rig's filename slugs
   to ASC display types (`iphone-17-pro-max-*` → `APP_IPHONE_67`, the
   API's current largest-iPhone slot, labeled 6.9" in ASC's media
   manager; `iphone-17-*` → `APP_IPHONE_61`). There is no
   `APP_IPHONE_69` enum case — verified against the
   `ScreenshotDisplayType` documentation, 2026-07-10.

## Usage

```sh
# Dry run (the default; no credentials needed, zero network access):
swift scripts/asc-listing.swift

# Everything, for real, attaching TestFlight build 17:
swift scripts/asc-listing.swift --apply --build 17

# Metadata only:
swift scripts/asc-listing.swift --apply --skip-screenshots
```

Flags: `--apply` (execute; otherwise the full API-call plan is printed
and nothing runs), `--build <n>` (attach a processed build to the
version), `--screenshots-dir <dir>`, `--skip-screenshots`, `--dry-run`
(explicit form of the default).

## What it does (and how it stays idempotent)

| Step | Source | Idempotency |
|---|---|---|
| Fetch-or-create the `appStoreVersions` record for the `MARKETING_VERSION` in `project.yml` | `project.yml` | Filtered GET first; POST only on miss — never duplicates a version |
| en-US version localization: description, keywords, promotional text, what's new, support + marketing URLs | `listing.md` (fenced blocks + Identity table) | GET localization, create if absent, then PATCH |
| App-info localization: name, subtitle, privacy policy URL | `listing.md` Identity table | PATCH per appInfo; the live (read-only) copy rejects it harmlessly |
| Age-rating declarations (classic questionnaire: everything None/false → 4+) | `listing.md` § Age rating | PATCH of the existing declaration resource |
| Screenshots: reserve → chunked PUT per `uploadOperations` → commit with MD5 `sourceFileChecksum` | `docs/app-store/screenshots/` | Files already in the set with the same name+size are skipped |
| Review details: contact (config) + notes | `review-notes.md` paste-ready block (truncated at 4000 chars with a warning) | GET; POST on first run, PATCH after |
| Build attach (`--build`) | ASC builds list (`processingState=VALID`) | Relationship PATCH is naturally idempotent |

Character limits (name/subtitle 30, keywords 100, promotional 170,
description/what's-new 4000) are enforced against the markdown before
any call — a kit edit that blows a limit fails fast in dry-run.

## Left manual, on purpose

- **Submission** (see above).
- **App Privacy labels** — ASC's `appDataUsages` flow is easy to get
  subtly wrong; enter them by hand from
  [privacy-labels.md](privacy-labels.md).
- **Newer age-rating questions** (advertising, in-app UGC, health
  topics, messaging, etc.) — their ASC semantics aren't covered by the
  listing kit's questionnaire table; the script sets only the classic
  declarations and reminds you at the end.
- **Categories** (Lifestyle / Health & Fitness) — one-time picker in
  ASC.

API shapes (asset upload flow, `ScreenshotDisplayType`, attribute sets
for localizations/review details/age rating) were verified against
<https://developer.apple.com/documentation/appstoreconnectapi> on
2026-07-10 rather than recalled.
