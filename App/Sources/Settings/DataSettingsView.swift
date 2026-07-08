import DispatchKit
import SwiftData
import SwiftUI

struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ThemeStore.self) private var themeStore

    @State private var shareURL: IdentifiableURL?
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showAlert = false

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

                    Button {
                        exportCSV()
                    } label: {
                        settingsLabel("Export as CSV")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("export-csv-button")

                    Button {
                        isImporting = true
                    } label: {
                        settingsLabel("Import…")
                    }
                    .listRowBackground(Color.white.opacity(0.12))
                    .accessibilityIdentifier("import-button")
                } header: {
                    sectionHeader("EXPORT & IMPORT")
                }
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

    private func importFile(at url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let summary = try importData(data)
            try VocabularyBuilder.rebuild(in: context)
            let reports = try context.fetch(FetchDescriptor<Report>())
            SpotlightIndexer.rebuildAll(reports: reports)
            presentAlert(
                "Imported \(summary.questionsImported) questions, \(summary.reportsImported) reports, "
                    + "\(summary.responsesImported) responses. Skipped: \(summary.skipped)."
            )
        } catch {
            presentAlert("Import failed: \(error.localizedDescription)")
        }
    }

    /// Sniffs the file format by probing for a top-level `schemaVersion` key (present
    /// only in v2 exports) and routes to the matching importer.
    private func importData(_ data: Data) throws -> ImportSummary {
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
