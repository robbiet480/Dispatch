# Dispatch Plan 25: iCloud Drive backups (iCloud Documents)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rotating backups additionally sync to iCloud Drive — a visible "Dispatch" folder containing flat JSON backup files, synced to the user's Mac and other devices.

**Context:** Robbie requested this 2026-07-09; it was gated on the health-in-iCloud review question, which he has since RISK-ACCEPTED (see docs/app-store/review-readiness.md §1) — so backups ship full-fat (health readings included; same accepted risk as CloudKit sync).

## Design decisions (decide + log)

- **Ubiquity container = the existing `iCloud.io.robbie.Dispatch`** (containers serve both CloudKit and Documents). New entitlement value: `com.apple.developer.icloud-services` gains `CloudDocuments` alongside `CloudKit`, plus `com.apple.developer.ubiquity-container-identifiers` = [iCloud.io.robbie.Dispatch]. **This is the first entitlement change since the profiles were pinned** — MUST be archive-proven; if the pinned App Store profiles reject it, recreate both profiles via the ASC API (the session ledger holds the exact curl recipe from 2026-07-08: bundle IDs 2532PZDYH6/VYY3Q8UZPQ, POST /v1/profiles with the current cert) and update nothing else. Budget this into the task.
- **Visible folder:** `NSUbiquitousContainers` Info.plist entry (partial-plist merge, the established pattern) with `NSUbiquitousContainerIsDocumentScopePublic = true` and a container name — required for the folder to appear in iCloud Drive/Files/Finder. Note: Apple caches container visibility aggressively; the report should mention the known "bump the build number / reboot" dance if the folder doesn't appear during device testing.
- **Write path:** `BackupManager` gains a destination mode (defaults-backed setting): Local (current), iCloud Drive, or Both (default becomes **Both** when iCloud is available — belt and braces; local remains the guaranteed copy). iCloud writes go to `FileManager.url(forUbiquityContainerIdentifier:)/Documents/Backups/` — same filenames, same rotation (rotation runs per-destination). `url(forUbiquityContainerIdentifier:)` is BLOCKING/slow — resolve once off-main at manager init, cache, nil = iCloud unavailable → local-only with a settings status line ("iCloud Drive unavailable").
- **Conflict/quota realities:** backups are write-once files with unique names — no conflict resolution needed; rotation deletes via FileManager (evict-then-delete not required for our own writes). Quota-full writes fail → logged, status row shows it, local copy unaffected.
- **Settings:** the Backups section gains the destination picker + an "Open in Files" hint. Identifier `backup-destination`.

## Global Constraints

- Suites green before every commit; scoped commits + push (standing instruction); test-gated (ubiquity never touched under test args — injected directory as today). Do NOT bump the build number. Entitlement change requires archive + codesign proof BEFORE the commit that relies on it; profile recreation via the API recipe if needed (document exactly what was required).

---

### Task 1: Entitlement + ubiquity plumbing + destination modes

**Files:** Modify `App/Dispatch.entitlements` (CloudDocuments + ubiquity-container-identifiers), `App/Info.plist` (NSUbiquitousContainers), `App/Sources/Backup/BackupManager.swift` (destination modes, cached ubiquity URL, per-destination rotation), `App/Sources/Settings/DataSettingsView.swift` (picker + status), `Sources/DispatchKit/Backup/BackupRotation.swift` only if rotation needs a directory parameter it lacks; kit tests for any changed rotation logic.

**Contract:** per design decisions verbatim. Archive + codesign dump proving both entitlement values on the app (widget target unchanged); if signing fails against the pinned profiles: recreate profiles via the ASC API recipe, reinstall, re-prove, and document the recreation in the report. Kit tests for destination-mode selection logic (pure part); UI suite green (Backups section renders the picker under test args with a stubbed unavailable state).

Verify: build, kit suite, UI suite, archive+codesign proof. Commit `feat: iCloud Drive backups` → push. Whole-branch review rides with whatever wave ships this (small plan; controller may batch it).
