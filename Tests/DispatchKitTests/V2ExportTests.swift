import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func exportsV2JSON() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let data = try V2Exporter.exportData(from: context)
    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: data)

    #expect(decoded.schemaVersion == 2)
    #expect(decoded.questions.count == 7)
    #expect(decoded.reports.count == 3)

    let snap1 = try #require(decoded.reports.first { $0.uniqueIdentifier == "snap-1" })
    #expect(snap1.kind == .regular)
    #expect(snap1.trigger == .manual)
    #expect(snap1.legacyImpetus == 0)
    #expect(snap1.timeZone == TimeZone(secondsFromGMT: -4 * 3600)!.identifier)
    #expect(snap1.health?.first { $0.type == "steps" }?.value == 481)
    #expect(snap1.responses?.count == 4)

    let multi = try #require(decoded.questions.first { $0.uniqueIdentifier == "q-multi" })
    #expect(multi.questionType == QuestionType.multipleChoice.rawValue)
    #expect(multi.reportKinds == [.regular])
}

@Test func exportIsDeterministic() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)
    let first = try V2Exporter.exportData(from: context)
    let second = try V2Exporter.exportData(from: context)
    #expect(first == second) // sorted keys + sorted records
}
