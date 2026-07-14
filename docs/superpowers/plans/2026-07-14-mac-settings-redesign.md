# macOS Settings Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace the single-window `MacSettingsView` (a 480pt `Form`) with native macOS **toolbar-tabbed preference panes** — `Settings { TabView { General / Sync / Data / About } }` — per the approved spec `docs/superpowers/specs/2026-07-14-macos-settings-redesign-design.md`.

**Architecture:** Four Mac-native `Form` panes under `Mac/Sources/Settings/`, each a `.tabItem` in a `TabView` inside the `Settings` scene. Reuse the backing stores/kit logic (never the iOS View layer). System-native appearance (the deliberate inverse of the themed main-window panes). `BackupManager` is injected into the Settings scene — it's a hard requirement for the Data pane's delete flow, and unlocks Back Up Now.

**Tech Stack:** SwiftUI `Settings`/`TabView`/`Form(.grouped)`, SwiftData, CloudKit (`CKAccountStatus`), DispatchKit.

## Global Constraints

- **macOS only.** New files live under `Mac/Sources/Settings/` (auto-join DispatchMac via the `Mac/Sources` glob — no project.yml edit for new Mac files). The one exception: `App/Sources/Backup/BackupManager.swift` must be added as an explicit `- path:` entry under DispatchMac in `project.yml` (it's iOS-target-only today), then `xcodegen generate`.
- **System-native appearance** — panes are plain `Form(.formStyle(.grouped))`; do NOT apply the app theme to Settings chrome.
- **Per-pane sizing** — each pane sets the SAME `.frame(minWidth: 500)` and lets height fit. There is no auto-sizing; matching min widths keep tab switches from jumping the window.
- **Reuse controllers/kit, not iOS Views** — `DataSettingsView`/`ICloudSettingsView`/`SyncDiagnosticsView` are iOS-only (UIKit, iOS-only stores) and must NOT be added to the Mac target. Re-author Mac-native panes binding only Mac-available stores.
- **Delete All Data — preserve BOTH gates; Mac deletion core only.** Reproduce the two-stage flow (see Task 3 spec). The actual erase calls ONLY the kit-side core: `DeleteAllData.deleteAllModels(in:)` → `DefaultQuestions.seedIfEmpty(into:)` → `DeleteAllData.clearRuntimeDefaults(appDefaults)` → (opt-in) `backupManager.deleteAllBackups()`. DROP all iOS cleanup (Spotlight, notifications, widgets, webhooks, Spotify) — none exist on Mac. Dropping a *gate* or silently deleting backups is a data-loss regression; dropping the iOS *cleanup* is correct.
- **Diagnostics is OUT of scope** (tracked by issue #103) — omit the affordance, do not stub it.
- **Delete confirm = a disabled button** (`.disabled(text != "DELETE")`), not a runtime check.
- Commit footer EXACTLY: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Don't push (controller pushes).
- Verify: `xcodegen generate`; `xcodebuild -scheme DispatchMac -destination 'platform=macOS' build` → SUCCEEDED after each task.

---

## Task 1: Inject BackupManager into the Settings scene

**Files:** `project.yml` (add BackupManager to DispatchMac sources), `Mac/Sources/DispatchMacApp.swift` (construct + inject).

**Interfaces (from the dependency map):**
- `BackupManager` (`App/Sources/Backup/BackupManager.swift`, `@MainActor @Observable`, un-gated, compiles on Mac): `init(container:defaults:isTestEnvironment:directory:iCloudDirectory:storeCreatedAt:isSyncActive:)`; `func backUpNow(now:)`; `func deleteAllBackups()`; state `isBackingUp`, `lastBackupDate`, `backupCount`, `isEnabled`, `destination`.
- `DispatchMacApp.init` already has: `container`, `appDefaults`, `isTestEnvironment`, and `cloudKitActive` (2nd elem of `makeContainer` return, DispatchMacApp.swift:40) → pass as `isSyncActive:`. Use `storeCreatedAt: nil` (only affects the first-launch auto-backup guard, which Back Up Now bypasses).

**Steps:**
- Add `- path: App/Sources/Backup/BackupManager.swift` to the DispatchMac `sources:` list in project.yml.
- In `DispatchMacApp`, add `let backupManager: BackupManager`, construct it in `init` after the container/appDefaults are ready.
- Inject `.environment(backupManager)` into the `Settings { }` scene block (currently DispatchMacApp.swift:171-177).
- `xcodegen generate`; DispatchMac build → SUCCEEDED (proves BackupManager compiles into the Mac target + injects).

---

## Task 2: The four preference panes

**Files (create):** `Mac/Sources/Settings/GeneralSettingsPane.swift`, `SyncSettingsPane.swift`, `DataSettingsPane.swift`, `AboutSettingsPane.swift`. Each is a `struct …: View` with `Form { … }.formStyle(.grouped).frame(minWidth: 500)`, reading its stores from `@Environment`. Keep all existing accessibility identifiers where they carry over.

### 2a. GeneralSettingsPane (`gearshape`)
- **Appearance** section: the theme `Picker` (reuse `MacSettingsView`'s exact picker — `ThemeStore.theme` binding, `Theme.allCases`, `ThemeColor.color(theme)`, `theme.displayName`, id `theme-picker`).
- A footnote: "Reports are filed on your iPhone or Apple Watch and sync here." (Settings stays system-native — no theme applied to the pane chrome.)

### 2b. SyncSettingsPane (`arrow.triangle.2.circlepath`)
- **iCloud Sync** `Toggle` bound through `SyncPolicy(defaults: appDefaults, isTestEnvironment:).userPreference` (reuse `MacSettingsView`'s toggle logic + `hasLoadedToggle` guard + `.onAppear`; id `icloud-sync-toggle`) with the "Takes effect after reopening…" footer.
- **Account status** — `@State accountStatusText`; `.task { await load() }` where `load()` is test-env-gated and does `try await CKContainer(identifier: SyncPolicy.containerIdentifier).accountStatus()` mapped via a `text(for: CKAccountStatus)` helper (available/noAccount/restricted/couldNotDetermine/temporarilyUnavailable). `import CloudKit`. id `icloud-account-status`.
- **Last store change observed** — `LabeledContent` from `RemoteChangeObserver.lastEventDate` (reuse `MacSettingsView.lastActivityText`).
- **Back Up Now** — `Button("Back Up Now") { backupManager.backUpNow() }.disabled(backupManager.isBackingUp)` (id `backup-now`) + a caption line from `backupManager.lastBackupDate`/`backupCount` (id `backup-caption`). No Diagnostics (issue #103).

### 2c. DataSettingsPane (`externaldrive`) — see Task 3 for the delete flow
- **Import**: `Button("Import…") { exportController.importJSON() }.disabled(exportController.isImportRunning)` (id `import-button`).
- **Export** as a clean labeled list (not a button jam) — one row each: Day One JSON (`exportDayOne`), Markdown Folder (`exportMarkdown`), Dispatch JSON (`exportDispatchJSON`), CSV (`exportCSV`), Questions JSON (`exportQuestionsJSON`), Questions CSV (`exportQuestionsCSV`).
- **Delete All Data** — Task 3.
- Present `exportController.message`/`isShowingMessage` in an `.alert` (reuse `MacSettingsView`'s alert).

### 2d. AboutSettingsPane (`info.circle`)
- `LabeledContent("Version", value:)` (short+build), `LabeledContent("Sync container", value: SyncPolicy.containerIdentifier)`, "carrying the torch of Reporter" blurb, `Link("View on GitHub", …)` (id `github-link`). (Reuse `MacSettingsView`'s About section verbatim.)

**Verify:** DispatchMac build → SUCCEEDED (panes compile; not yet wired).

---

## Task 3: Delete All Data — the two-stage gate (in DataSettingsPane)

Reproduce the iOS `DataSettingsView` flow exactly, Mac-native, deletion core only.

**State:** `@State showScopeAlert=false`, `deleteBackupsToo=false`, `showTypeConfirm=false`, `confirmText=""`, `isDeleting=false`, `showSuccess=false`. `@Environment(\.modelContext)`, `@Environment(\.appDefaults)`, `@Environment(BackupManager.self)`.

**Trigger:** `Button("Delete All Data…", role: .destructive) { showScopeAlert = true }.disabled(isDeleting || exportController.isImportRunning).foregroundStyle(.red)` (id `delete-all-data`).

**Stage 1 — scope alert** `.alert("Delete All Data?", isPresented: $showScopeAlert)`:
- `Button("Delete Data Only", role: .destructive) { deleteBackupsToo=false; confirmText=""; showTypeConfirm=true }`
- `Button("Also Delete Backups", role: .destructive) { deleteBackupsToo=true; confirmText=""; showTypeConfirm=true }`
- `Button("Cancel", role: .cancel) {}`
- message: base sentence + a `SyncPolicy(...).shouldSync`-conditional sentence (iCloud copy erased as deletions sync / sync off → clears next enable) + "Consider exporting first. Backups are kept unless you also delete them." (Backups default OFF = the safe path, encoded as the secondary destructive button.)

**Stage 2 — typed DELETE** `.alert("Confirm Deletion", isPresented: $showTypeConfirm)`:
- `TextField("Type DELETE to confirm", text: $confirmText).autocorrectionDisabled()` (id `delete-confirm-field`)
- `Button("Delete Everything", role: .destructive) { deleteAllData(includeBackups: deleteBackupsToo) }.disabled(confirmText != "DELETE")`  ← disabled-button gate
- `Button("Cancel", role: .cancel) {}`
- message: "This cannot be undone. Type DELETE to confirm."

**Deleting overlay:** while `isDeleting`, a `ProgressView("Deleting…")` overlay (id `delete-all-progress`).

**Stage 3 — success:** `.alert("All Data Deleted", isPresented: $showSuccess)` → OK; message "Dispatch has been reset to its default questions."

**`deleteAllData(includeBackups:)`** — set `isDeleting=true`; off-main on `ModelContext(context.container)`: `try DeleteAllData.deleteAllModels(in:)` then `DefaultQuestions.seedIfEmpty(into:)`; back on main: `DeleteAllData.clearRuntimeDefaults(appDefaults)`, `if includeBackups { backupManager.deleteAllBackups() }`, `isDeleting=false`, `showSuccess=true`. DROP all iOS cleanup. Handle throw → `isDeleting=false` + an error alert.

**Verify:** DispatchMac build → SUCCEEDED.

---

## Task 4: Wire the Settings scene + remove MacSettingsView + smoke test

**Files:** `Mac/Sources/DispatchMacApp.swift` (Settings scene), delete `Mac/Sources/MacSettingsView.swift`, `MacUITests/` (smoke test).

**Steps:**
- Replace `Settings { MacSettingsView()… }` with:
  ```swift
  Settings {
      TabView {
          GeneralSettingsPane().tabItem { Label("General", systemImage: "gearshape") }
          SyncSettingsPane().tabItem    { Label("Sync",    systemImage: "arrow.triangle.2.circlepath") }
          DataSettingsPane().tabItem    { Label("Data",    systemImage: "externaldrive") }
          AboutSettingsPane().tabItem   { Label("About",   systemImage: "info.circle") }
      }
      .environment(themeStore).environment(remoteChangeObserver)
      .environment(exportController).environment(backupManager)
      .environment(\.appDefaults, appDefaults)
  }
  ```
- Delete `MacSettingsView.swift` (fully replaced). Confirm nothing else references it (`grep`).
- **Smoke test** (`MacUITests/MacSettingsUITests.swift`, NOT SCREENSHOT_MODE-gated): launch (`--mock-sensors --ui-testing --demo-data`), open Settings via ⌘, (`app.typeKey(",", modifierFlags: .command)`), select the Data tab, assert `delete-all-data` exists; tap it → assert the scope alert's "Delete Data Only" / "Also Delete Backups" buttons; choose one → assert `delete-confirm-field` exists and "Delete Everything" is **disabled**; type "DELETE" → assert it enables; Cancel out (do NOT actually delete). Keep it resilient to the menu-open-notification flake (prefer ⌘, keyboard over clicking the app menu).
- Verify: DispatchMac build → SUCCEEDED; the new Mac UI test passes locally (screen-driven — run on the unlocked Mac).

---

## Self-review
- Spec coverage: General/Sync/Data/About all present; delete two-stage preserved; BackupManager injected; system-native; per-pane min width; Diagnostics deferred to #103 (documented).
- No iOS View reused; deletion core is kit-only; iOS cleanup dropped.
- New Mac files auto-join the target; only BackupManager needs a project.yml entry.
