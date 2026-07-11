import AppKit
import DispatchKit
import os
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let exportLog = Logger(subsystem: "io.robbie.Dispatch", category: "export")

/// Drives the Mac import/export flows (plan 36): NSSavePanel for the
/// single-file exports (Day One JSON, Dispatch JSON, CSV), an NSOpenPanel
/// folder pick + per-file writes for the Markdown/Obsidian export, and an
/// NSOpenPanel + format-sniffing import (v1 Reporter JSON / v2 Dispatch
/// JSON — the same probe DataSettingsView uses on iOS). All file access is
/// user-driven through the powerbox, so the sandbox needs no standing
/// grants beyond `files.user-selected.read-write`.
@MainActor
@Observable
final class MacExportController {
    private let container: ModelContainer

    /// Result surface: MacRootView presents this in an alert.
    var message: String?
    var isShowingMessage = false
    var isImportRunning = false

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Exports

    func exportDayOne() {
        savePanelExport(suggestedName: "Dispatch Day One Export.json", type: .json) { context in
            let reports = try context.fetch(FetchDescriptor<Report>())
            return try DayOneExporter.export(reports: reports)
        }
    }

    func exportDispatchJSON() {
        savePanelExport(suggestedName: "dispatch-export.json", type: .json) { context in
            try V2Exporter.exportData(from: context)
        }
    }

    func exportCSV() {
        savePanelExport(suggestedName: "dispatch-export.csv", type: .commaSeparatedText) { context in
            Data(try CSVExporter.exportCSV(from: context).utf8)
        }
    }

    /// One `.md` per report into a user-chosen folder — pick an empty folder
    /// and it opens directly as an Obsidian vault.
    func exportMarkdown() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the Markdown files (one per report)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let files = MarkdownExporter.export(
                reports: try ModelContext(container).fetch(FetchDescriptor<Report>()))
            for file in files {
                try Data(file.contents.utf8)
                    .write(to: folder.appending(path: file.filename), options: .atomic)
            }
            present("Exported \(files.count) Markdown file\(files.count == 1 ? "" : "s") to \(folder.lastPathComponent).")
        } catch {
            exportLog.error("markdown export failed: \(error, privacy: .public)")
            present("Markdown export failed: \(error.localizedDescription)")
        }
    }

    private func savePanelExport(suggestedName: String, type: UTType,
                                 produce: (ModelContext) throws -> Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try produce(ModelContext(container))
            try data.write(to: url, options: .atomic)
            present("Exported \(url.lastPathComponent).")
        } catch {
            exportLog.error("export failed: \(error, privacy: .public)")
            present("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// v1 Reporter JSON or v2 Dispatch JSON, sniffed by the top-level
    /// `schemaVersion` key (v2-only) — same routing as iOS.
    func importJSON() {
        guard !isImportRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose a Reporter (v1) or Dispatch (v2) JSON export."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let container = self.container
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
                await MainActor.run { [weak self] in
                    self?.isImportRunning = false
                    self?.present(
                        "Imported \(summary.questionsImported) questions, \(summary.reportsImported) reports, "
                            + "\(summary.responsesImported) responses. Skipped: \(summary.skipped)."
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isImportRunning = false
                    self?.present("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private nonisolated static func importData(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        struct SchemaProbe: Decodable { let schemaVersion: Int }
        if (try? JSONDecoder().decode(SchemaProbe.self, from: data)) != nil {
            return try V2Importer.importExport(data, into: context)
        }
        return try V1Importer.importExport(data, into: context)
    }

    private func present(_ text: String) {
        message = text
        isShowingMessage = true
    }
}
