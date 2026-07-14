import DispatchKit
import os
import SwiftData
import SwiftUI

private let deleteAllLog = Logger(subsystem: "io.robbie.Dispatch", category: "delete-all")

/// Settings → Data: import, the export list, and the two-stage Delete All Data
/// flow.
///
/// The delete flow mirrors the iOS `DataSettingsView` gates exactly (scope
/// choice, then a typed-DELETE confirmation), but the erase itself calls ONLY
/// the kit-side core — `DeleteAllData.deleteAllModels` → `DefaultQuestions
/// .seedIfEmpty` → `DeleteAllData.clearRuntimeDefaults` → (opt-in)
/// `BackupManager.deleteAllBackups`. The iOS cleanup (Spotlight, notifications,
/// widgets, webhooks, Spotify) is dropped on purpose: none of those surfaces
/// exist on the Mac.
struct DataSettingsPane: View {
    @Environment(\.modelContext) private var context
    @Environment(MacExportController.self) private var exportController
    @Environment(BackupManager.self) private var backupManager
    @Environment(\.appDefaults) private var appDefaults

    // Delete All Data flow state — both gates, same shape as iOS.
    @State private var showScopeAlert = false
    @State private var showTypeConfirm = false
    @State private var deleteBackupsToo = false
    @State private var confirmText = ""
    @State private var isDeleting = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Reporter/Dispatch JSON") {
                    Button("Import…") { exportController.importJSON() }
                        .accessibilityIdentifier("import-button")
                        .disabled(exportController.isImportRunning)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Reporter (v1) and Dispatch (v2) JSON exports are both accepted — the format is sniffed from the file.")
            }

            Section {
                exportRow("Day One JSON") { exportController.exportDayOne() }
                exportRow("Markdown Folder") { exportController.exportMarkdown() }
                exportRow("Dispatch JSON") { exportController.exportDispatchJSON() }
                exportRow("CSV") { exportController.exportCSV() }
                exportRow("Questions JSON") { exportController.exportQuestionsJSON() }
                exportRow("Questions CSV") { exportController.exportQuestionsCSV() }
            } header: {
                Text("Export")
            } footer: {
                Text("Everything here also lives in the File menu.")
            }

            Section {
                Button("Delete All Data…", role: .destructive) {
                    showScopeAlert = true
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("delete-all-data")
                .disabled(isDeleting || exportController.isImportRunning)
            } header: {
                Text("Danger Zone")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView("Deleting…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("delete-all-progress")
                }
                .ignoresSafeArea()
            }
        }
        // The Settings window is its own scene — it needs its own alert
        // surface for import/export results triggered from here.
        .alert("Dispatch", isPresented: Binding(
            get: { exportController.isShowingMessage },
            set: { exportController.isShowingMessage = $0 }
        ), presenting: exportController.message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        // Delete-all gate 1: scope explanation + the backups choice. Alerts
        // can't host a Toggle, so "Also Delete Backups" (default OFF — backups
        // are the safety net) is the secondary destructive button.
        .alert("Delete All Data?", isPresented: $showScopeAlert) {
            Button("Delete Data Only", role: .destructive) {
                deleteBackupsToo = false
                confirmText = ""
                showTypeConfirm = true
            }
            Button("Also Delete Backups", role: .destructive) {
                deleteBackupsToo = true
                confirmText = ""
                showTypeConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteScopeMessage)
        }
        // Delete-all gate 2: type-to-confirm — this is irreversible. The gate
        // is the DISABLED button, not a runtime string check.
        .alert("Confirm Deletion", isPresented: $showTypeConfirm) {
            TextField("Type DELETE to confirm", text: $confirmText)
                .autocorrectionDisabled()
                .accessibilityIdentifier("delete-confirm-field")
            Button("Delete Everything", role: .destructive) {
                // Defense in depth. `.disabled` below is the affordance; THIS is
                // the gate. SwiftUI has not been consistent across releases about
                // re-evaluating a `.disabled` alert button as its bound TextField
                // changes, and the action behind it is an irreversible full wipe —
                // so re-check the typed confirmation at the moment of the tap.
                // (iOS's DataSettingsView relies on exactly this runtime check.)
                guard confirmText == "DELETE" else { return }
                deleteAllData(includeBackups: deleteBackupsToo)
            }
            .disabled(confirmText != "DELETE")
            Button("Cancel", role: .cancel) { resetDeleteGates() }
        } message: {
            Text("This cannot be undone. Type DELETE to confirm.")
        }
        .alert("All Data Deleted", isPresented: $showSuccess) {
            Button("OK") {}
        } message: {
            Text("Dispatch has been reset to its default questions.")
        }
        .alert("Delete Failed", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func exportRow(_ title: String, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            Button("Export…", action: action)
        }
    }

    private var isTestEnvironment: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
    }

    /// CloudKit honesty: row deletions reach the user's private database only
    /// while mirroring can run. With sync off (or forced off in tests) say so
    /// instead of promising an immediate server-side erase.
    private var deleteScopeMessage: String {
        var text = "Deletes every report, question, prompt group, and vocabulary entry, "
            + "then restores the default questions."
        let syncActive = SyncPolicy(
            defaults: appDefaults, isTestEnvironment: isTestEnvironment
        ).shouldSync
        if syncActive {
            text += " Your iCloud copy is erased as the deletions sync."
        } else {
            text += " iCloud sync is off — your iCloud copy, if any, will clear next time sync is enabled."
        }
        text += " Consider exporting first. Backups are kept unless you also delete them."
        return text
    }

    /// Executes the wipe off-main: one background-context pass over every model
    /// with a SINGLE save (CloudKit mirroring propagates the deletions
    /// server-side — deliberately no direct CKContainer zone purge; see
    /// `DeleteAllData` in DispatchKit for the rationale), then the reseed, then
    /// the main-actor cleanup.
    private func deleteAllData(includeBackups: Bool) {
        guard !isDeleting else { return }
        let container = context.container
        isDeleting = true
        Task.detached(priority: .userInitiated) {
            do {
                let backgroundContext = ModelContext(container)
                let counts = try DeleteAllData.deleteAllModels(in: backgroundContext)
                // Reseed the frozen default-question catalog into the
                // now-empty store; deterministic UUIDv5 IDs keep the reseed
                // sync-safe (a second device merges, never duplicates).
                try DefaultQuestions.seedIfEmpty(into: backgroundContext)
                let summary = "\(counts.reports) reports, \(counts.responses) responses, "
                    + "\(counts.questions) questions, \(counts.promptGroups) prompt groups, "
                    + "\(counts.tokens) tokens, \(counts.people) people"
                deleteAllLog.info("deleted all data: \(summary, privacy: .public)")
                await MainActor.run {
                    finishDeleteAllData(includeBackups: includeBackups)
                }
            } catch {
                deleteAllLog.error("delete all data failed: \(error, privacy: .public)")
                await MainActor.run {
                    isDeleting = false
                    resetDeleteGates()
                    errorMessage = "Delete failed: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }

    /// Disarms both gates. Gate 1 already scrubs this state on the way IN, so
    /// nothing today can reach gate 2 pre-authorized — but leaving a spent
    /// `confirmText == "DELETE"` and an armed `deleteBackupsToo` lying around
    /// means any future path that raises `showTypeConfirm` without going
    /// through gate 1 (a retry affordance, a deep link, state restoration)
    /// would present gate 2 already filled in, its button already enabled and
    /// its runtime guard already satisfied: one tap from a full wipe with both
    /// gates skipped. Scrub on the way OUT too, so that trap never gets armed.
    private func resetDeleteGates() {
        confirmText = ""
        deleteBackupsToo = false
    }

    private func finishDeleteAllData(includeBackups: Bool) {
        // Runtime defaults keyed to the deleted data — the kit-side lists
        // document every cleared AND retained key. No App Group suite on the
        // Mac (no widgets/intents read this store), no Spotlight index, no
        // notification schedule, no webhook/Spotify credentials: the iOS
        // cleanup those needed has no counterpart here.
        DeleteAllData.clearRuntimeDefaults(appDefaults)
        if includeBackups {
            backupManager.deleteAllBackups()
        }
        isDeleting = false
        resetDeleteGates()
        showSuccess = true
    }
}
