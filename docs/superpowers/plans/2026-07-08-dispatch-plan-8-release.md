# Dispatch Plan 8: Release Prep (import/export UI, icon, manifest, README, signed archive)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A TestFlight-uploadable build: users can import their original Reporter export and export their data; the app has an icon, privacy manifest, README, version 0.1.0 (build 1), and a signed .ipa archived with team UTQFCBPQRF waiting for upload.

**Scope decisions (logged):** iCloud sync, nightly auto-backup, and the deep accessibility pass are deferred post-TestFlight (entitlement/container risk and time). Export = v2 JSON + CSV via share sheet; backups list deferred with iCloud.

## Global Constraints

- Import accepts BOTH v1 (original Reporter, `{"questions":[],"snapshots":[]}`) and v2 (`schemaVersion: 2`) files — sniff the format (v2 has schemaVersion key), route to V1Importer/V2Importer, then `VocabularyBuilder.rebuild` + Spotlight `rebuildAll`. Import summary shown to the user (reports/questions/responses counts, skipped).
- Lenient v1 decoding (carried spec item): wrap `V1Export` snapshot/question array elements in a failable-decode container so one malformed record is skipped+counted, not fatal. DispatchKit + tests.
- App icon: original geometric design generated in-repo (Swift/Python script writing a 1024×1024 PNG — flat tomato background, white-outlined hexagon of triangles motif; NO copying the original Reporter icon), placed in an asset catalog wired via project.yml.
- Privacy manifest (PrivacyInfo.xcprivacy) declaring collected data types (health, location, audio level, photos metadata, coarse behavioral) all "not linked, not tracked, app-functionality only", plus required-reason API entries for UserDefaults (CA92.1).
- Version 0.1.0 / build 1; DEVELOPMENT_TEAM UTQFCBPQRF; archive via `xcodebuild archive` + `exportArchive` (method app-store-connect / debugging fallback documented if signing needs the user's session).
- README: original prose — what Dispatch is, credit to the original Reporter app as inspiration, feature list, build instructions (xcodegen, entitlements notes), import instructions, license note, screenshots section placeholder (real screenshots require the user's device — leave a TODO list item for him rather than fake it).
- No delegation; suites green; commit+push per task.

---

### Task 1: DispatchKit — lenient v1 import

**Files:** Modify `Sources/DispatchKit/V1/V1Models.swift` (failable element decoding), `Sources/DispatchKit/Import/V1Importer.swift` (skipped counting). Test: extend `Tests/DispatchKitTests/V1ImporterTests.swift`.

**Contract:** a v1 file with one structurally-broken snapshot (e.g. wrong-typed field) imports the rest; `ImportSummary.skipped` counts it; malformed QUESTIONS likewise skipped. Test with an inline JSON fixture containing one good + one broken snapshot. Existing byte-equality round-trip tests must stay green.

### Task 2: App — import/export UI

**Files:** Create `App/Sources/Settings/DataSettingsView.swift`; modify SettingsView DATA section, SurveyController/SpotlightIndexer call sites as needed.

**Contract:** DATA section → Data screen: EXPORT AS JSON (v2, share sheet via ShareLink/UIActivity), EXPORT AS CSV (share sheet), IMPORT… (fileImporter accepting .json → sniff v1/v2 → import → alert with summary counts → VocabularyBuilder.rebuild + Spotlight rebuildAll). Identifiers `export-json-button`, `export-csv-button`, `import-button`. Themed. iCloud row stays "Coming soon".

### Task 3: Icon, manifest, versioning, README

**Files:** Create `scripts/generate-icon.swift` (or .py) + `App/Assets.xcassets/AppIcon.appiconset/`; `App/PrivacyInfo.xcprivacy`; modify project.yml (asset catalog, manifest resource, MARKETING_VERSION 0.1.0, CURRENT_PROJECT_VERSION 1, DEVELOPMENT_TEAM UTQFCBPQRF); create README.md.

**Contract:** per Global Constraints. Icon script committed + run (single 1024 icon, iOS single-size). README references LICENSE, no personal data.

### Task 4: Archive + wrap

**Contract:** run all three suites; then `xcodebuild archive -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS' -archivePath build/Dispatch.xcarchive DEVELOPMENT_TEAM=UTQFCBPQRF -allowProvisioningUpdates` and `xcodebuild -exportArchive` with an app-store-connect ExportOptions.plist. If signing/provisioning requires interactive Apple ID auth unavailable tonight, produce the archive as far as possible, document the exact one-command finish for the user, and verify the archive exists. Commit remaining files; whole-branch review (controller-driven) follows.
