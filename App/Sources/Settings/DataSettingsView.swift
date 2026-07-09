import DispatchKit
import SwiftData
import SwiftUI

struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ThemeStore.self) private var themeStore
    @Environment(BackupManager.self) private var backupManager

    @State private var shareURL: IdentifiableURL?
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var isImportRunning = false

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
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
