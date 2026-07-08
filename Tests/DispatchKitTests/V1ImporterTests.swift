import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func importsFixture() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    #expect(summary.questionsImported == 7)
    #expect(summary.reportsImported == 3)
    #expect(summary.responsesImported == 9)
    #expect(summary.skipped == 0)

    let reports = try context.fetch(FetchDescriptor<Report>())
    let snap1 = try #require(reports.first { $0.uniqueIdentifier == "snap-1" })
    // v1 steps land in the health array.
    #expect(snap1.health.first { $0.type == "steps" }?.value == 481)
    #expect(snap1.legacyImpetus == 0)
    #expect(snap1.trigger == .manual)
    #expect(snap1.timeZoneIdentifier == TimeZone(secondsFromGMT: -4 * 3600)!.identifier)
    #expect(snap1.weather?.condition == "Mostly Cloudy")
    #expect(snap1.location?.placemark?.locality == "Riverton")

    let snap2 = try #require(reports.first { $0.uniqueIdentifier == "snap-2" })
    #expect(snap2.photos.count == 1)
    #expect(snap2.trigger == .notification) // impetus 2 = notification-initiated
    #expect(snap2.connectionType == .wifi)  // connection 1
    #expect(snap2.responses.count == 3)

    // impetus 4 = wake report: kind and trigger recovered from v1 data.
    let snap3 = try #require(reports.first { $0.uniqueIdentifier == "snap-3" })
    #expect(snap3.kind == .wake)
    #expect(snap3.trigger == .wake)

    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.count == 7)
    // Imported multi-choice questions have no options (v1 export lacks them).
    let multi = try #require(questions.first { $0.uniqueIdentifier == "q-multi" })
    #expect(multi.choices.isEmpty)
    // Sort order follows export order.
    #expect(questions.sorted { $0.sortOrder < $1.sortOrder }.first?.uniqueIdentifier == "q-tokens")
}

@Test func importIsIdempotent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let data = try fixtureData("v1-sample")
    _ = try V1Importer.importExport(data, into: context)
    _ = try V1Importer.importExport(data, into: context)

    #expect(try context.fetch(FetchDescriptor<Report>()).count == 3)
    #expect(try context.fetch(FetchDescriptor<Question>()).count == 7)
    #expect(try context.fetch(FetchDescriptor<Response>()).count == 9)
}

@Test func importsRealExportIfPresent() throws {
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(try Data(contentsOf: URL(fileURLWithPath: path)), into: context)
    #expect(summary.reportsImported == 94)
    #expect(summary.questionsImported == 38)
    #expect(summary.skipped == 0)
}

@Test func skipsMalformedSnapshotButImportsGoodOnes() throws {
    // One good snapshot, one malformed (bad date type).
    let json = Data("""
    {"questions": [{"questionType": 0, "prompt": "Test", "uniqueIdentifier": "q-1"}], "snapshots": [
        {"uniqueIdentifier": "snap-good", "date": "2016-02-11T19:08:54-0400"},
        {"uniqueIdentifier": "snap-bad", "date": {"nested": true}}
    ]}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(json, into: context)

    #expect(summary.reportsImported == 1)
    #expect(summary.skipped == 1)
    let reports = try context.fetch(FetchDescriptor<Report>())
    #expect(reports.count == 1)
    #expect(reports.first?.uniqueIdentifier == "snap-good")
}

@Test func skipsMalformedQuestionButImportsGoodOnes() throws {
    // One good question, one malformed (missing required field).
    let json = Data("""
    {"questions": [
        {"questionType": 0, "prompt": "Good Q", "uniqueIdentifier": "q-good"},
        {"questionType": 1, "uniqueIdentifier": "q-bad"}
    ], "snapshots": []}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V1Importer.importExport(json, into: context)

    #expect(summary.questionsImported == 1)
    #expect(summary.skipped == 1)
    let questions = try context.fetch(FetchDescriptor<Question>())
    #expect(questions.count == 1)
    #expect(questions.first?.uniqueIdentifier == "q-good")
}
