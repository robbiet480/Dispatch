import Foundation
import SwiftData
import Testing
@testable import DispatchKit

/// Determinism is a shared contract across all four exporters: exporting the
/// SAME fixture twice must produce byte-identical output (sorted keys + sorted
/// records). This one parameterized test replaces the per-exporter
/// determinism tests that used to live in each exporter's file
/// (markdownOutputIsDeterministic, dayOneOutputIsDeterministic, V2
/// exportIsDeterministic) and adds CSV, which previously had no such test.
///
/// The four exporters DON'T share a clean call site — CSV/V2 export from a
/// `ModelContext`, Markdown/DayOne from `[Report]`, and their return types
/// differ (String / Data / [(filename, contents)]). So each case carries its
/// own closure that builds a fresh fixture and returns the two exports as
/// `Data`; the test asserts they're identical, uniformly.
private struct ExporterCase: Sendable, CustomTestStringConvertible {
    let name: String
    let run: @Sendable () throws -> (Data, Data)
    var testDescription: String { name }
}

/// Build a report carrying three prompts in deliberately non-alphabetical
/// order — the exporters must impose their own stable ordering, not trust
/// relationship order.
private func unorderedPromptReport() -> Report {
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    for prompt in ["Zebra?", "Apple?", "Mango?"] {
        let response = Response()
        response.questionPrompt = prompt
        response.tokens = [TokenValue(text: "x")]
        response.report = report
        report.responses = (report.responses ?? []) + [response]
    }
    return report
}

/// Serialize Markdown's `[(filename, contents)]` output into a single blob so
/// determinism can be asserted as `Data` alongside the other exporters.
private func markdownBlob<Files: Sequence>(_ files: Files) -> Data
where Files.Element == (filename: String, contents: String) {
    Data(files.map { "\($0.filename)\n\($0.contents)" }.joined(separator: "\u{01}").utf8)
}

private let exporterDeterminismCases: [ExporterCase] = [
    ExporterCase(name: "CSV") {
        let context = ModelContext(try DispatchStore.inMemoryContainer())
        _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)
        return (Data(try CSVExporter.exportCSV(from: context).utf8),
                Data(try CSVExporter.exportCSV(from: context).utf8))
    },
    ExporterCase(name: "Markdown") {
        let context = ModelContext(try DispatchStore.inMemoryContainer())
        context.insert(unorderedPromptReport())
        let reports = try context.fetch(FetchDescriptor<Report>())
        return (markdownBlob(MarkdownExporter.export(reports: reports)),
                markdownBlob(MarkdownExporter.export(reports: reports)))
    },
    ExporterCase(name: "DayOne") {
        let context = ModelContext(try DispatchStore.inMemoryContainer())
        context.insert(unorderedPromptReport())
        let reports = try context.fetch(FetchDescriptor<Report>())
        return (try DayOneExporter.export(reports: reports),
                try DayOneExporter.export(reports: reports))
    },
    ExporterCase(name: "V2") {
        let context = ModelContext(try DispatchStore.inMemoryContainer())
        _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)
        return (try V2Exporter.exportData(from: context, stamp: fixedStamp),
                try V2Exporter.exportData(from: context, stamp: fixedStamp))
    },
]

@Test(arguments: exporterDeterminismCases)
private func exporterOutputIsDeterministic(_ exporter: ExporterCase) throws {
    let (first, second) = try exporter.run()
    #expect(first == second)
}
