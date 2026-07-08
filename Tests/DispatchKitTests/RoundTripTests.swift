import Foundation
import SwiftData
import Testing
@testable import DispatchKit

/// v1 fixture → models → v2 JSON → fresh models → v2 JSON must be byte-identical.
@Test func v1ToV2RoundTripIsLossless() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: contextA)
    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    let summary = try V2Importer.importExport(exportA, into: contextB)
    #expect(summary.questionsImported == 7)
    #expect(summary.reportsImported == 3)
    #expect(summary.responsesImported == 8)

    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}

@Test func v2ImportIsIdempotent() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: contextA)
    let data = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(data, into: contextB)
    _ = try V2Importer.importExport(data, into: contextB)
    #expect(try contextB.fetch(FetchDescriptor<Report>()).count == 3)
    #expect(try contextB.fetch(FetchDescriptor<Response>()).count == 8)
}

@Test func v2ImportRejectsWrongSchemaVersion() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let bad = Data(#"{"schemaVersion": 3, "questions": [], "reports": []}"#.utf8)
    #expect(throws: V2Importer.ImportError.unsupportedSchemaVersion(3)) {
        try V2Importer.importExport(bad, into: context)
    }
}

/// A report date with sub-second precision must survive export -> import ->
/// export byte-identically, i.e. the v2 wire format must not truncate fractional seconds.
@Test func fractionalSecondDateRoundTripsByteIdentically() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let report = Report()
    report.uniqueIdentifier = "frac-report"
    report.date = Date(timeIntervalSince1970: 1_700_000_000.123456)
    report.timeZoneIdentifier = "GMT"
    contextA.insert(report)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let exportB = try V2Exporter.exportData(from: contextB)

    #expect(exportA == exportB)

    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: exportA)
    let importedDate = try #require(decoded.reports.first?.date)
    #expect(abs(importedDate.timeIntervalSince1970 - report.date.timeIntervalSince1970) < 0.001)
}

@Test func realExportRoundTripsIfPresent() throws {
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    _ = try V1Importer.importExport(try Data(contentsOf: URL(fileURLWithPath: path)), into: contextA)
    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}
