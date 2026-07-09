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
    #expect(summary.responsesImported == 9)

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
    #expect(try contextB.fetch(FetchDescriptor<Response>()).count == 9)
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

/// A build-5 export carries legacy seeded identifiers (`default-question-<N>`).
/// Importing it into a post-migration store must map those IDs through the
/// frozen migration table — upserting into the existing UUIDv5 rows instead of
/// inserting duplicates — and remap response/group references. Non-legacy IDs
/// pass through untouched.
@Test func v2ImportMapsLegacyDefaultQuestionIDs() throws {
    // Store A: a build-5-style store, legacy IDs everywhere.
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let legacyQuestion = Question()
    legacyQuestion.uniqueIdentifier = "default-question-1"
    legacyQuestion.prompt = "Are you working?"
    contextA.insert(legacyQuestion)
    let customQuestion = Question()
    customQuestion.uniqueIdentifier = "custom-question"
    customQuestion.prompt = "Custom?"
    contextA.insert(customQuestion)
    let report = Report()
    report.uniqueIdentifier = "legacy-report"
    contextA.insert(report)
    let response = Response()
    response.uniqueIdentifier = "legacy-response"
    response.questionIdentifier = "default-question-1"
    response.report = report
    contextA.insert(response)
    let customResponse = Response()
    customResponse.uniqueIdentifier = "custom-response"
    customResponse.questionIdentifier = "custom-question"
    customResponse.report = report
    contextA.insert(customResponse)
    let group = PromptGroup()
    group.uniqueIdentifier = "legacy-group"
    group.questionIDs = ["default-question-1", "custom-question"]
    contextA.insert(group)
    try contextA.save()
    let exportA = try V2Exporter.exportData(from: contextA)

    // Store B: post-migration — the seeded question already has its
    // deterministic UUID identity.
    let migratedID = DefaultQuestions.all[1].identifier
    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    let migrated = Question()
    migrated.uniqueIdentifier = migratedID
    migrated.prompt = "Are you working?"
    contextB.insert(migrated)
    try contextB.save()

    _ = try V2Importer.importExport(exportA, into: contextB)

    let questions = try contextB.fetch(FetchDescriptor<Question>())
    #expect(questions.count == 2) // migrated seed + custom, NO duplicate
    #expect(questions.map(\.uniqueIdentifier).sorted() == [migratedID, "custom-question"].sorted())
    #expect(!questions.contains { $0.uniqueIdentifier == "default-question-1" })

    let responses = try contextB.fetch(FetchDescriptor<Response>())
    let byID = Dictionary(uniqueKeysWithValues: responses.map { ($0.uniqueIdentifier, $0) })
    #expect(byID["legacy-response"]?.questionIdentifier == migratedID)
    #expect(byID["custom-response"]?.questionIdentifier == "custom-question")

    let groups = try contextB.fetch(FetchDescriptor<PromptGroup>())
    #expect(groups.first?.questionIDs == [migratedID, "custom-question"])
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
