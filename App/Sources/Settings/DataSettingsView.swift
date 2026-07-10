import DispatchKit
import os
import SwiftData
import SwiftUI
import UserNotifications

private let deleteAllLog = Logger(subsystem: "io.robbie.Dispatch", category: "delete-all")

struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ThemeStore.self) private var themeStore
    @Environment(BackupManager.self) private var backupManager
    @Environment(NotificationScheduler.self) private var scheduler
    @Environment(AwakeStore.self) private var awakeStore
    @Environment(\.notificationPrefs) private var notificationPrefs
    @Environment(\.appDefaults) private var appDefaults
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: IdentifiableURL?
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var isImportRunning = false

    // Delete All Data flow state (review-readiness blocker #2).
    @State private var showDeleteScopeAlert = false
    @State private var showDeleteTypeConfirm = false
    @State private var deleteBackupsToo = false
    @State private var deleteConfirmationText = ""
    @State private var isDeleting = false
    @State private var showDeleteSuccess = false

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    Button {
                        exportJSON()
                    } label: {
                        settingsLabel("Export as JSON")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("export-json-button")
                    .disabled(isImportRunning)

                    Button {
                        exportCSV()
                    } label: {
                        settingsLabel("Export as CSV")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("export-csv-button")
                    .disabled(isImportRunning)

                    Button {
                        isImporting = true
                    } label: {
                        if isImportRunning {
                            HStack {
                                settingsLabel("Import…")
                                Spacer()
                                ProgressView()
                                    .tint(.white)
                                    .accessibilityIdentifier("import-progress")
                            }
                        } else {
                            settingsLabel("Import…")
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("import-button")
                    .disabled(isImportRunning)
                } header: {
                    sectionHeader("EXPORT & IMPORT")
                }

                backupsSection

                deleteSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if isDeleting {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                ProgressView("Deleting…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("delete-all-progress")
            }
        }
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $shareURL) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImportResult(result)
        }
        .alert("Import", isPresented: $showAlert, presenting: alertMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        // Delete-all gate 1: scope explanation + the backups choice. Alerts
        // can't host a Toggle, so "Also delete backups" (default OFF —
        // backups are the safety net) is the secondary destructive button.
        .alert("Delete All Data?", isPresented: $showDeleteScopeAlert) {
            Button("Delete Data Only", role: .destructive) {
                deleteBackupsToo = false
                deleteConfirmationText = ""
                showDeleteTypeConfirm = true
            }
            Button("Also Delete Backups", role: .destructive) {
                deleteBackupsToo = true
                deleteConfirmationText = ""
                showDeleteTypeConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteScopeMessage)
        }
        // Delete-all gate 2: type-to-confirm — this is irreversible.
        .alert("Confirm Deletion", isPresented: $showDeleteTypeConfirm) {
            TextField("Type DELETE to confirm", text: $deleteConfirmationText)
                .autocorrectionDisabled()
                .accessibilityIdentifier("delete-confirm-field")
            Button("Delete Everything", role: .destructive) {
                if deleteConfirmationText == "DELETE" {
                    deleteAllData(includeBackups: deleteBackupsToo)
                } else {
                    presentAlert("Confirmation text didn't match — nothing was deleted.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Type DELETE to confirm.")
        }
        .alert("All Data Deleted", isPresented: $showDeleteSuccess) {
            Button("OK") { dismiss() }
        } message: {
            Text("Dispatch has been reset to its default questions.")
        }
    }

    // MARK: - Backups (plan 16)

    /// Automatic rotating backups: enabled toggle (default ON), last-backup
    /// caption + count, and a manual "Back Up Now" that ignores staleness.
    private var backupsSection: some View {
        Section {
            Toggle("Automatic Backups", isOn: Binding(
                get: { backupManager.isEnabled },
                set: { backupManager.isEnabled = $0 }
            ))
            .tint(.white.opacity(0.4))
            .foregroundStyle(.white)
            .accessibilityIdentifier("backup-enabled")

            Button {
                backupManager.backUpNow()
            } label: {
                if backupManager.isBackingUp {
                    HStack {
                        settingsLabel("Back Up Now")
                        Spacer()
                        ProgressView()
                            .tint(.white)
                    }
                } else {
                    settingsLabel("Back Up Now")
                }
            }
            .accessibilityIdentifier("backup-now")
            .disabled(backupManager.isBackingUp)
        } header: {
            sectionHeader("BACKUPS")
        } footer: {
            Text(backupCaption)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("backup-caption")
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    private var backupCaption: String {
        var lines = [String]()
        if let last = backupManager.lastBackupDate {
            lines.append("Last backup: \(last.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            lines.append("No backups yet.")
        }
        let count = backupManager.backupCount
        lines.append(count == 1 ? "1 backup kept." : "\(count) backups kept (newest 14).")
        lines.append("Daily JSON exports in the Files app under On My iPhone → Dispatch → Backups. "
            + "iCloud sync is not a backup — sync propagates deletions; backups let you rewind.")
        return lines.joined(separator: " ")
    }

    // MARK: - Delete All Data (review-readiness blocker #2)

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteScopeAlert = true
            } label: {
                Text("Delete All Data…")
                    .foregroundStyle(.red)
            }
            .listRowBackground(Color.white.opacity(0.12))
            .accessibilityIdentifier("delete-all-data")
            .disabled(isDeleting || isImportRunning)
        } header: {
            sectionHeader("DANGER ZONE")
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
        text += " Consider exporting first. Backups in the Files app are kept unless you also delete them."
        return text
    }

    /// Executes the wipe off-main: one background-context pass over every
    /// model with a SINGLE save (CloudKit mirroring propagates the deletions
    /// server-side — deliberately no direct CKContainer zone purge; see
    /// `DeleteAllData` in DispatchKit for the rationale), then the reseed,
    /// then the main-actor cleanup of everything that referenced the data.
    private func deleteAllData(includeBackups: Bool) {
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
                    presentAlert("Delete failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishDeleteAllData(includeBackups: Bool) {
        // Spotlight: wipe the whole index (test-gated inside the indexer).
        SpotlightIndexer.deleteAll()
        // Notifications: remove EVERY identifier family (prompt-/gprompt-/
        // snooze-/nag-/digest-), pending and delivered — removeAll is exactly
        // that set. Test-gated like the scheduler's own center access.
        if !isTestEnvironment {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
        // Runtime defaults keyed to the deleted data — the kit-side lists
        // document every cleared AND retained key.
        DeleteAllData.clearRuntimeDefaults(appDefaults)
        if isTestEnvironment {
            // Tests run everything against the single isolated suite.
            DeleteAllData.clearAppGroupDefaults(appDefaults)
        } else if let groupDefaults = UserDefaults(suiteName: StoreLocation.appGroupID) {
            DeleteAllData.clearAppGroupDefaults(groupDefaults)
        }
        if includeBackups {
            backupManager.deleteAllBackups()
        }
        // Fresh schedule for the reseeded questions; the replan republishes
        // the widget's next-prompt date. Reload timelines so widgets drop to
        // placeholder/fresh content immediately.
        scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
        if !isTestEnvironment {
            WidgetRefresher.reload()
        }
        isDeleting = false
        showDeleteSuccess = true
    }

    // MARK: - Export

    private func exportJSON() {
        do {
            let data = try V2Exporter.exportData(from: context)
            let url = try writeTempFile(data: data, name: "dispatch-export.json")
            shareURL = IdentifiableURL(url: url)
        } catch {
            presentAlert("Export failed: \(error.localizedDescription)")
        }
    }

    private func exportCSV() {
        do {
            let csv = try CSVExporter.exportCSV(from: context)
            guard let data = csv.data(using: .utf8) else {
                presentAlert("Export failed: could not encode CSV data.")
                return
            }
            let url = try writeTempFile(data: data, name: "dispatch-export.csv")
            shareURL = IdentifiableURL(url: url)
        } catch {
            presentAlert("Export failed: \(error.localizedDescription)")
        }
    }

    private func writeTempFile(data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            presentAlert("Import failed: \(error.localizedDescription)")
        case .success(let url):
            importFile(at: url)
        }
    }

    /// Import runs off the main actor: file read, `V1Importer`/`V2Importer`, and
    /// `VocabularyBuilder.rebuild` all execute against a background
    /// `ModelContext(container)` inside a detached `Task`, so a large import
    /// never blocks scrolling/animation on the Data screen. The background
    /// context saves its own changes; SwiftData propagates those saves to the
    /// main context's `@Query`-backed views automatically via its persistent
    /// history mechanism (same container, same store) — this is the same
    /// cross-context pattern already used by `NotificationScheduler`, which
    /// creates and mutates through its own `ModelContext(container)` off the
    /// main actor. `SpotlightIndexer.rebuildAll` is safe to call from the
    /// background task too: it immediately snapshots the `[Report]` models it
    /// is given into a `Sendable` value type before any async work runs, so
    /// no non-Sendable SwiftData model crosses an actor boundary.
    private func importFile(at url: URL) {
        let container = context.container
        isImportRunning = true
        Task.detached(priority: .userInitiated) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let backgroundContext = ModelContext(container)
                let summary = try Self.importData(data, into: backgroundContext)
                try VocabularyBuilder.rebuild(in: backgroundContext)
                let reports = try backgroundContext.fetch(FetchDescriptor<Report>())
                SpotlightIndexer.rebuildAll(reports: reports)
                await MainActor.run {
                    isImportRunning = false
                    // Widgets read the shared store directly but get no
                    // change notifications — poke them after an import lands.
                    WidgetRefresher.reload()
                    presentAlert(
                        "Imported \(summary.questionsImported) questions, \(summary.reportsImported) reports, "
                            + "\(summary.responsesImported) responses. Skipped: \(summary.skipped)."
                    )
                }
            } catch {
                await MainActor.run {
                    isImportRunning = false
                    presentAlert("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Sniffs the file format by probing for a top-level `schemaVersion` key (present
    /// only in v2 exports) and routes to the matching importer.
    ///
    /// `nonisolated` + `static`: this must run on the background task's thread
    /// alongside the background `ModelContext`, not be forced back onto the
    /// main actor just because `DataSettingsView` (a View) is main-actor
    /// isolated by default.
    private nonisolated static func importData(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        struct SchemaProbe: Decodable { let schemaVersion: Int }
        if (try? JSONDecoder().decode(SchemaProbe.self, from: data)) != nil {
            return try V2Importer.importExport(data, into: context)
        }
        return try V1Importer.importExport(data, into: context)
    }

    private func presentAlert(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    // MARK: - Shared styling

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.white)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
