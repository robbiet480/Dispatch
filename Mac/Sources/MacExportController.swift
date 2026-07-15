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

    /// Result surface. Both Mac scenes (main window + Settings) observe this
    /// controller, so the message carries the scene that triggered it and only
    /// that scene presents — otherwise the confirmation appears in both windows
    /// at once. See `ResultMessageState`.
    private(set) var messageState = ResultMessageState()
    var isImportRunning = false

    /// Clears the result message (bound to each scene's alert dismiss).
    func dismissMessage() {
        messageState.dismiss()
    }

    /// Plan 47: question-definition import preview state. The open panel +
    /// parse + plan run here; `QuestionSettingsView` (Task 2.3's shared Mac
    /// Questions pane) presents the preview sheet and calls
    /// `commitQuestionImport` on confirm.
    var questionImportPlan: QuestionImportPlan?
    var showingQuestionImport = false

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Exports

    func exportDayOne(from origin: ResultMessageState.Scene = .primary) {
        savePanelExport(suggestedName: "Dispatch Day One Export.json", type: .json, from: origin) { context in
            let reports = try context.fetch(FetchDescriptor<Report>())
            return try DayOneExporter.export(reports: reports)
        }
    }

    func exportDispatchJSON(from origin: ResultMessageState.Scene = .primary) {
        savePanelExport(suggestedName: "dispatch-export.json", type: .json, from: origin) { context in
            try V2Exporter.exportData(from: context)
        }
    }

    func exportCSV(from origin: ResultMessageState.Scene = .primary) {
        savePanelExport(suggestedName: "dispatch-export.csv", type: .commaSeparatedText, from: origin) { context in
            Data(try CSVExporter.exportCSV(from: context).utf8)
        }
    }

    /// One `.md` per report into a user-chosen folder — pick an empty folder
    /// and it opens directly as an Obsidian vault.
    func exportMarkdown(from origin: ResultMessageState.Scene = .primary) {
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
            present("Exported \(files.count) Markdown file\(files.count == 1 ? "" : "s") to \(folder.lastPathComponent).", from: origin)
        } catch {
            exportLog.error("markdown export failed: \(error, privacy: .public)")
            present("Markdown export failed: \(error.localizedDescription)", from: origin)
        }
    }

    // MARK: - Question definition export (plan 47, issue #57)

    /// Export the question DEFINITIONS (not report data) as JSON — mirrors the
    /// catalog seed shape so a personal export and a curated seed are the same
    /// file shape.
    func exportQuestionsJSON(from origin: ResultMessageState.Scene = .primary) {
        savePanelExport(suggestedName: "dispatch-questions.json", type: .json, from: origin) { context in
            try QuestionPortability.encodeJSON(Self.questionDefinitions(in: context))
        }
    }

    /// Export the question definitions as CSV (documented column schema).
    func exportQuestionsCSV(from origin: ResultMessageState.Scene = .primary) {
        savePanelExport(suggestedName: "dispatch-questions.csv", type: .commaSeparatedText, from: origin) { context in
            Data(QuestionPortability.encodeCSV(try Self.questionDefinitions(in: context)).utf8)
        }
    }

    private static func questionDefinitions(in context: ModelContext) throws -> [QuestionDefinition] {
        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)]))
        return questions.map(QuestionDefinition.init)
    }

    /// Open a CSV/JSON question file, parse it, and build a preview plan
    /// (adds/skips/errors) against the current questions. Presents the preview
    /// sheet; nothing is written until `commitQuestionImport`.
    func importQuestions(existingPrompts: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.prompt = "Import"
        panel.message = "Choose a question CSV or JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let definitions: [QuestionDefinition]
            if url.pathExtension.lowercased() == "csv" {
                definitions = try QuestionPortability.decodeCSV(String(decoding: data, as: UTF8.self))
            } else {
                definitions = try QuestionPortability.decodeJSON(data)
            }
            questionImportPlan = QuestionImportPlan.make(
                incoming: definitions, existingPrompts: existingPrompts)
            showingQuestionImport = true
        } catch {
            exportLog.error("question import parse failed: \(error, privacy: .public)")
            present("Question import failed: \(error.localizedDescription)")
        }
    }

    /// Commit the previewed adds into the store, appended after the existing
    /// questions (fresh identities — never collides with sync).
    func commitQuestionImport(into context: ModelContext) {
        defer {
            questionImportPlan = nil
            showingQuestionImport = false
        }
        guard let plan = questionImportPlan, !plan.adds.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<Question>())) ?? []
        var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        for definition in plan.adds {
            context.insert(definition.makeQuestion(sortOrder: nextOrder))
            nextOrder += 1
        }
        do {
            try context.save()
            present("Imported \(plan.adds.count) question\(plan.adds.count == 1 ? "" : "s").")
        } catch {
            exportLog.error("question import commit failed: \(error, privacy: .public)")
            present("Question import failed: \(error.localizedDescription)")
        }
    }

    private func savePanelExport(suggestedName: String, type: UTType,
                                 from origin: ResultMessageState.Scene = .primary,
                                 produce: (ModelContext) throws -> Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try produce(ModelContext(container))
            try data.write(to: url, options: .atomic)
            present("Exported \(url.lastPathComponent).", from: origin)
        } catch {
            exportLog.error("export failed: \(error, privacy: .public)")
            present("Export failed: \(error.localizedDescription)", from: origin)
        }
    }

    // MARK: - Import

    /// v1 Reporter JSON or v2 Dispatch JSON, sniffed by the top-level
    /// `schemaVersion` key (v2-only) — same routing as iOS.
    func importJSON(from origin: ResultMessageState.Scene = .primary) {
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
                            + "\(summary.responsesImported) responses. Skipped: \(summary.skipped).",
                        from: origin
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isImportRunning = false
                    self?.present("Import failed: \(error.localizedDescription)", from: origin)
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

    // Defaults to `.primary`: File-menu and Questions-pane results belong to the
    // main window. The Settings Data pane passes `.settings` so its own
    // export/import confirmations stay in the Settings window.
    private func present(_ text: String, from origin: ResultMessageState.Scene = .primary) {
        messageState.present(text, from: origin)
    }
}
